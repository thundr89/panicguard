#!/bin/bash

# A script elérési útvonala
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Azonosító kulcs, amit a scriptedben is használsz
SECRET_KEY='your_secret_key'

# A központi szerver URL-je
CENTRAL_SERVER_URL='192.168.0.242/panicguard.php'

# A bannolt IP-címek helyi listája
LOCAL_BANNED_IPS='local_banned_ips.txt'

# A saját IP-cím lekérése
MY_IP_ADDRESS=$(curl -s https://ipinfo.io/ip)


APACHE_LOG="/var/log/apache2/error.log"
JOURNALCTL_LOG="journalctl --no-full"
MYSQL_LOG="/var/log/mysql/error.log"
WEBMIN_LOG="/var/webmin/miniserv.error"

# Beállítási varázsló függvény
setup_wizard() {
    echo "Welcome to PanicGuard! Let's set up your configuration."

    # Ellenőrzi, hogy a szükséges programok telepítve vannak-e
    for cmd in mail curl ufw; do
        if ! command -v $cmd &> /dev/null; then
            echo "$cmd is not installed."
            read -p "Would you like to install it? (sudo required) (y/n): " install_choice
            if [[ $install_choice == "y" ]]; then
                sudo apt install $cmd
            fi
        fi
    done

    if [ -n "$MAILTO" ]; then
        read -p "Current email is $MAILTO. Would you like to change it? (y/n): " change_email
        if [[ $change_email == "y" ]]; then
            read -p "Enter your new email address: " MAILTO
        fi
    else
        read -p "Would you like to receive email notifications? (y/n): " email_choice
        if [[ $email_choice == "y" ]]; then
            read -p "Enter your email address: " MAILTO
        fi
    fi
    if [ -n "$WEBHOOK_URL" ]; then
        read -p "Current webhook URL is $WEBHOOK_URL. Would you like to change it? (y/n): " change_webhook
        if [[ $change_webhook == "y" ]]; then
            read -p "Enter your new webhook URL: " WEBHOOK_URL
        fi
    else
        read -p "Would you like to receive webhook notifications? (y/n): " webhook_choice
        if [[ $webhook_choice == "y" ]]; then
            read -p "Enter your webhook URL: " WEBHOOK_URL
        fi
    fi
    if [ -n "$ASSERVICE" ]; then
        read -p "Current setting is to run as service: $ASSERVICE. Would you like to change it? (y/n): " change_service
        if [[ $change_service == "y" ]]; then
            read -p "Would you like to run the script as a service? (y/n): " ASSERVICE
        fi
    else
        read -p "Would you like to run the script as a service? (y/n): " ASSERVICE
    fi
    # HTML riport készítésének beállítása
    if [ -n "$HTML_REPORT" ]; then
        read -p "Current setting for HTML report generation is: $HTML_REPORT. Would you like to change it? (y/n): " change_html_report
        if [[ $change_html_report == "y" ]]; then
            read -p "Would you like to generate an HTML report? (y/n): " HTML_REPORT
            if [[ $HTML_REPORT == "y" ]]; then
                read -p "Enter the directory where you want to save the HTML report: " REPORT_DIR
            fi
        fi
    else
        read -p "Would you like to generate an HTML report? (y/n): " HTML_REPORT
        if [[ $HTML_REPORT == "y" ]]; then
            read -p "Enter the directory where you want to save the HTML report: " REPORT_DIR
        fi
    fi

    # Globális szinkronizáció beállítása
    if [ -n "$GLOBAL_SYNC" ]; then
        read -p "Current setting for global synchronization is: $GLOBAL_SYNC. Would you like to change it? (y/n): " change_global_sync
        if [[ $change_global_sync == "y" ]]; then
            read -p "Would you like to enable global synchronization? (y/n): " GLOBAL_SYNC
        fi
    else
        read -p "Would you like to enable global synchronization? (y/n): " GLOBAL_SYNC
    fi

    # A többi beállítás itt következik...

    echo "MAILTO=$MAILTO" > "$SCRIPT_DIR/panicguard.cnf"
    echo "WEBHOOK_URL=$WEBHOOK_URL" >> "$SCRIPT_DIR/panicguard.cnf"
    echo "ASSERVICE=$ASSERVICE" >> "$SCRIPT_DIR/panicguard.cnf"
    echo "HTML_REPORT=$HTML_REPORT" >> "$SCRIPT_DIR/panicguard.cnf"
    echo "REPORT_DIR=$REPORT_DIR" >> "$SCRIPT_DIR/panicguard.cnf"
    echo "GLOBAL_SYNC=$GLOBAL_SYNC" >> "$SCRIPT_DIR/panicguard.cnf"

    if [[ $ASSERVICE == "y" ]]; then
        if [ "$EUID" -ne 0 ]; then
            echo "Please run the script with sudo and --installservice to install the service."
            sudo $0 --installservice
        else
            install_service
        fi
    fi
    echo "Configuration saved. The script will now continue."
}

# Beállítások beolvasása a konfigurációs fájlból
if [ -f "$SCRIPT_DIR/panicguard.cnf" ]; then
    source "$SCRIPT_DIR/panicguard.cnf"
fi

# Függvény a bannok visszaállításához
restore_bans() {
    echo "Restoring bans from log files..."
    for log_file in $OUTPUT_DIR/*.log; do
        while IFS= read -r line; do
            ip=$(echo $line | grep -oP '(?<=\[client ).*(?=])' | cut -d':' -f1)
            if ! ufw status | grep -q $ip; then
                COMMENT=$(echo $line | grep -oP '(?<=banned by panicguard > ).*(?=, reason: )')
                if [[ $1 == "--manually" ]]; then
                    read -p "Would you like to restore the ban for IP: $ip? (y/n): " restore_choice
                    if [[ $restore_choice == "y" ]]; then
                        ufw deny from $ip comment "$COMMENT"
                        echo "Restored ban for IP: $ip"
                    fi
                else
                    ufw deny from $ip comment "$COMMENT"
                    echo "Restored ban for IP: $ip"
                fi
            fi
        done < "$log_file"
    done
    echo "Ban restoration completed."
}
# Új függvény a sorok feldolgozásához
process_line() {
    local line=$1
    local mode=$2

    if echo $line | grep -Pq "$error_pattern"; then
        ip=$(echo $line | grep -oP '(?<=\[client ).*(?=])' | cut -d':' -f1)
        # Ellenőrizze, hogy az IP-cím nem a saját, a helyi hálózaton található-e, vagy a központi szerver IP-címe
        if [[ ! $ip =~ ^192\.168\. || ! $ip =~ ^10\. || ! $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. || $ip != "$MY_IP_ADDRESS" ]]; then
            echo "$line" >> $output_file
            COMMENT="banned by panicguard > $(date +%Y-%m-%d:%H:%M), reason: $error"
            if [[ $mode == "--manually" ]]; then
                read -p "Would you like to ban IP: $ip? (y/n): " ban_choice
                if [[ $ban_choice == "y" ]]; then
                    ufw deny from $ip comment "$COMMENT"
                    echo "Banned IP: $ip"
                    if command -v mail &> /dev/null; then
                        echo "Banned IP: $ip, $COMMENT" | mail -s "UFW Ban" $MAILTO
                    else
                        echo "Email server is not set up on this system."
                    fi
                    curl -H "Content-Type: application/json" -X POST -d "{\"content\": \"Banned IP: $ip, $COMMENT\"}" $WEBHOOK_URL
                    total_bans=$((total_bans+1))
                    new_bans=$((new_bans+1))
                    last_ban="IP: ${ip%.*}.xx, Reason: $error"
                    generate_html_stats
                fi
            else
                ufw deny from $ip comment "$COMMENT"
                echo "Banned IP: $ip"
                if command -v mail &> /dev/null; then
                    echo "Banned IP: $ip, $COMMENT" | mail -s "UFW Ban" $MAILTO
                else
                    echo "Email server is not set up on this system."
                fi
                curl -H "Content-Type: application/json" -X POST -d "{\"content\": \"Banned IP: $ip, $COMMENT\"}" $WEBHOOK_URL
                total_bans=$((total_bans+1))
                new_bans=$((new_bans+1))
                last_ban="IP: ${ip%.*}.xx, Reason: $error"
                generate_html_stats
            fi
        fi
    fi
}

# Függvény a naplók feldolgozásához
process_logs() {
    local log_file=$1
    local error_pattern=$2
    local output_file="$OUTPUT_DIR/$(basename $log_file)_$(date +%Y%m%d%H%M%S).log"

    # Először végigolvassa az egész fájlt
    while IFS= read -r line
    do
        process_line "$line" "$1"
    done < "$log_file"

    # Majd figyeli az új bejegyzéseket
    tail -F $log_file | while IFS= read -r line
    do
        process_line "$line" "$1"
    done
}

# Függvény a szolgáltatás telepítéséhez
install_service() {
    echo "[Unit]
Description=PanicGuard Service

[Service]
ExecStart=$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/panicguard.service

    sudo systemctl daemon-reload
    sudo systemctl enable panicguard.service
    echo "PanicGuard service installed and enabled."
}

# Függvény a statisztikák kiírásához
print_stats() {
    echo "Total bans: $total_bans"
    echo "New bans: $new_bans"
}

generate_html_stats() {
    if [[ $HTML_REPORT == "y" ]]; then
        # HTML fájl generálása
        cat << EOF > "$REPORT_DIR/PanicGuard.html"
<!DOCTYPE html>
<html>
<head>
<title>PanicGuard Statistics</title>
</head>
<body>
<h1>PanicGuard Statistics</h1>
<p>Total bans: $total_bans</p>
<p>New bans: $new_bans</p>
<p>Last ban: $last_ban</p>
</body>
</html>
EOF
    fi
}

# Függvény a rendszer erőforrásainak kiírásához
print_resources() {
    echo "Printing system resources..."
    echo "Script CPU usage: $(ps -p $$ -o %cpu | tail -n 1)%"
    echo "Script memory usage: $(pmap $$ | tail -n 1 | awk '/total/ {print $2}')"
    echo "Script disk usage: $(du -sh "$SCRIPT_DIR" | cut -f1)"
    echo "System resources printed."
}

# Függvény a terminál kezeléséhez
handle_terminal() {
    while true; do
        read -p "> " cmd
        if [[ $cmd == "exit" ]]; then
            print_stats
            exit 0
        elif [[ $cmd == "stats" ]]; then
            print_stats
        elif [[ $cmd == "resources" ]]; then
            print_resources
        else
            echo "Unknown command: $cmd"
        fi
    done
}

# Ha a --wizard opció van megadva, akkor futtatja a beállítási varázslót
if [[ $1 == "--wizard" ]]; then
    setup_wizard
# Ha a --restore opció van megadva, akkor futtatja a bannok visszaállítását
elif [[ $1 == "--restore" ]]; then
    if [[ $2 == "--manually" ]]; then
        restore_bans --manually
    else
        restore_bans --headless
    fi
# Ha a --installservice opció van megadva, akkor telepíti a szolgáltatást
elif [[ $1 == "--installservice" ]]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Please run the script with sudo to install the service."
    else
        install_service
    fi
elif [[ $1 == "--exit" ]]; then
    print_stats
    exit 0
elif [[ $1 == "--scanlogs" ]]; then
	journalctl --no-full > /home/thundrhu/journal.log
    $JOURNALCTL_LOG = /home/journal.log
    process_logs $APACHE_LOG '\[core:error\]' --scan
    process_logs $JOURNALCTL_LOG 'Failed password for' --scan
    process_logs $MYSQL_LOG 'Access denied for user' --scan
    process_logs $WEBMIN_LOG 'Invalid login|Perl execution failed' --scan
    print_stats
    exit 0
else
    journalctl --no-full > /home/thundrhu/journal.log
    $JOURNALCTL_LOG = /home/journal.log
    # Naplók feldolgozása
    if [[ $1 == "--manually" ]]; then
        process_logs $APACHE_LOG '\[core:error\]' --manually &
        process_logs $JOURNALCTL_LOG 'Failed password for' --manually &
        process_logs $MYSQL_LOG 'Access denied for user' --manually &
        process_logs $WEBMIN_LOG 'Invalid login|Perl execution failed' --manually &
    else
        process_logs $APACHE_LOG '\[core:error\]' --headless &
        process_logs $JOURNALCTL_LOG 'Failed password for' --headless &
        process_logs $MYSQL_LOG 'Access denied for user' --headless &
        process_logs $WEBMIN_LOG 'Invalid login|Perl execution failed' --headless &
    fi
    handle_terminal
fi

# Függvény a bannolt IP-címek letöltéséhez
download_banned_ips() {
    if [[ $GLOBAL_SYNC == "y" ]]; then
        # Ellenőrzi, hogy a központi szerver elérhető-e
        if curl --output /dev/null --silent --head --fail "$CENTRAL_SERVER_URL"; then
            # Letölti a bannolt IP-címek listáját a központi szerverről
            curl -o new_banned_ips.txt "$CENTRAL_SERVER_URL?download=true&secret_key=$SECRET_KEY"
            # Összefűzi az újonnan letöltött IP-címeket a helyi listával, és eltávolítja a duplikátumokat
            cat $LOCAL_BANNED_IPS new_banned_ips.txt | sort | uniq > temp.txt
            mv temp.txt $LOCAL_BANNED_IPS
            rm new_banned_ips.txt
            echo "Synchronization completed."
        else
            echo "Central server is not available. Trying again in 1 hour..."
            sleep 1h
            download_banned_ips
        fi
    fi
}

# Függvény a letöltött IP-címek feldolgozásához
process_downloaded_ips() {
    if [[ $GLOBAL_SYNC == "y" ]]; then
        while IFS= read -r line
        do
            ip=$(echo $line | grep -oP '(?<=\[client ).*(?=])' | cut -d':' -f1)
            # Ellenőrizze, hogy az IP-cím nem a saját vagy a helyi hálózaton található-e
            if [[ ! $ip =~ ^192\.168\. || ! $ip =~ ^10\. || ! $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. || $ip != "$MY_IP_ADDRESS" ]]; then
                process_line "$line" "--headless"
            fi
        done < "$LOCAL_BANNED_IPS"
    fi
}

# A bannolt IP-címek letöltése naponta kétszer
while true; do
    if [[ $GLOBAL_SYNC == "y" ]]; then
        download_banned_ips
        process_downloaded_ips
        sleep 12h
    else
        sleep 24h
    fi
    
done
