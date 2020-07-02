#!/bin/sh
# suricata-manager - Suricata port for Merlin firmware supported routers
# Site: https://github.com/ttgapers/suricata-merlin
# Thread: https://www.snbforums.com/threads/release-surcata-merlin/
# Credits: rgnldo, Martineau, ttgapers, lonelycoder, Adamm, Jack Yaz

# shellcheck disable=SC2086,SC2068,SC2039,SC2242,SC2027,SC2155,SC2046
VER="v1.03"
#======================================================================================================= © 2020 Martineau, v1.03
#  Install 'suricata - Real-time Intrusion Detection System (IDS), Intrusion Prevention System (IPS) package from Entware on Asuswrt-Merlin firmware.
#
#  Pre-reqs:   4.x kernel e.g. HND-models RT-AC86U,RT-AX88U or RT-AX56U,RT-AX58U
#              QoS and AiProtection Trend Micro DISABLED
#              Skynet DISABLED recommended but may run concurrently
#
# Usage:    suricata_manager    ['help'|'-h'] | [ 'debug' ]
#                               [ 'install' | 'uninstall' | 'check' | 'stop' | 'start' | 'logs' | 'config[x]' | 'test' ]
#
#           suricata_manager    config
#                               View the suricata.yml file
#           suricata_manager    configx
#                               Edit the suricata.yml file
#           suricata_manager    check
#                               Syntax check the suricata.yml file
#           suricata_manager    test
#                               Generate a spoof HTTPS attack (To see it you will need to enable the http.log)
#
#                                       uid=0(root) gid=0(root) groups=0(root)
#           suricata_manager    logs
#                               View the default three logs for activity
#
#                                       ==> /opt/var/log/suricata/fast.log <==
#
#                                       ==> /opt/var/log/suricata/stats.log <==
#
#                                       ==> /opt/var/log/suricata/eve-2020-05-09-15:38.json <==



#
# filename: fast.log
# filename: unified2.alert
# filename: http.log
# filename: log.pcap
# filename: tls.log
# filename: stats.log
# filename: drop.log
# filename: files-json.log
# filename: dns.log
# filename: eve.json
# filename: /opt/var/log/suricata/suricata.log

# Print between line beginning with'#==' to first blank line inclusive
ShowHelp() {
  awk '/^#==/{f=1} f{print; if (!NF) exit}' $0
}
Say() {
  # shellcheck disable=SC2068
  echo -e $$ $@ | logger -st "($(basename $0))"
}
SayT() {
  # shellcheck disable=SC2068
  echo -e $$ $@ | logger -t "($(basename $0))"
}
# shellcheck disable=SC2034
ANSIColours () {
	cRESET="\e[0m";cBLA="\e[30m";cRED="\e[31m";cGRE="\e[32m";cYEL="\e[33m";cBLU="\e[34m";cMAG="\e[35m";cCYA="\e[36m";cGRA="\e[37m";cFGRESET="\e[39m"
	cBGRA="\e[90m";cBRED="\e[91m";cBGRE="\e[92m";cBYEL="\e[93m";cBBLU="\e[94m";cBMAG="\e[95m";cBCYA="\e[96m";cBWHT="\e[97m"
	aBOLD="\e[1m";aDIM="\e[2m";aUNDER="\e[4m";aBLINK="\e[5m";aREVERSE="\e[7m"
	aBOLDr="\e[21m";aDIMr="\e[22m";aUNDERr="\e[24m";aBLINKr="\e[25m";aREVERSEr="\e[27m"
	cWRED="\e[41m";cWGRE="\e[42m";cWYEL="\e[43m";cWBLU="\e[44m";cWMAG="\e[45m";cWCYA="\e[46m";cWGRA="\e[47m"
	cYBLU="\e[93;48;5;21m"
	cRED_="\e[41m";cGRE_="\e[42m"
	xHOME="\e[H";xERASE="\e[2J";xERASEDOWN="\e[J";xERASEUP="\e[1J";xCSRPOS="\e[s";xPOSCSR="\e[u";xERASEEOL="\e[K"
	xGoto="\e[Line;Columnf"
}
Get_Router_Model() {

	# Contribution by @thelonelycoder as odmpid is blank for non SKU hardware,
	local HARDWARE_MODEL
	[ -z "$(nvram get odmpid)" ] && HARDWARE_MODEL=$(nvram get productid) || HARDWARE_MODEL=$(nvram get odmpid)

	echo $HARDWARE_MODEL

	return 0
}
Chk_Entware() {

		# ARGS [wait attempts] [specific_entware_utility]
		READY="1"                   # Assume Entware Utilities are NOT available
		ENTWARE_UTILITY=""          # Specific Entware utility to search for
		MAX_TRIES="30"

		if [ -n "$2" ] && [ "$2" -eq "$2" ] 2>/dev/null; then
			MAX_TRIES="$2"
		elif [ -z "$2" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
			MAX_TRIES="$1"
		fi

		if [ -n "$1" ] && ! [ "$1" -eq "$1" ] 2>/dev/null; then
			ENTWARE_UTILITY="$1"
		fi

		# Wait up to (default) 30 seconds to see if Entware utilities available.....
		TRIES="0"

		while [ "$TRIES" -lt "$MAX_TRIES" ]; do
			if [ -f "/opt/bin/opkg" ]; then
				if [ -n "$ENTWARE_UTILITY" ]; then            # Specific Entware utility installed?
					if [ -n "$(opkg list-installed "$ENTWARE_UTILITY")" ]; then
						READY="0"                             # Specific Entware utility found
					else
						# Not all Entware utilities exists as a stand-alone package e.g. 'find' is in package 'findutils'
						if [ -d /opt ] && [ -n "$(find /opt/ -name "$ENTWARE_UTILITY")" ]; then
							READY="0"                         # Specific Entware utility found
						fi
					fi
				else
					READY="0"                                 # Entware utilities ready
				fi
				break
			fi
			sleep 1
			logger -st "($(basename "$0"))" "$$ Entware $ENTWARE_UTILITY not available - wait time $((MAX_TRIES - TRIES-1)) secs left"
			TRIES=$((TRIES + 1))
		done
		return "$READY"
}
Is_HND() {
	# Use the following at the command line otherwise 'return X' makes the SSH session terminate!
	#[ -n "$(uname -m | grep "aarch64")" ] && echo Y || echo N
	[ -n "$(uname -m | grep "aarch64")" ] && { echo Y; return 0; } || { echo N; return 1; }
}
Is_AX() {
	# Kernel is '4.1.52+' (i.e. isn't '2.6.36*') and it isn't HND
	# Use the following at the command line otherwise 'return X' makes the SSH session terminate!
	# [ -n "$(uname -r | grep "^4")" ] && [ -z "$(uname -m | grep "aarch64")" ] && echo Y || echo N
	[ -n "$(uname -r | grep "^4")" ] && [ -z "$(uname -m | grep "aarch64")" ] && { echo Y; return 0; } || { echo N; return 1; }
}
# shellcheck disable=SC2034
Get_WAN_IF_Name () {

	# echo $([ -n "$(nvram get wan0_pppoe_ifname)" ] && echo $(nvram get wan0_pppoe_ifname) || echo $(nvram get wan0_ifname))
	#	nvram get wan0_gw_ifname
	#	nvram get wan0_proto

	local IF_NAME=$(nvram get wan0_ifname)				# DHCP/Static ?

	# Usually this is probably valid for both eth0/ppp0e ?
	if [ "$(nvram get wan0_gw_ifname)" != "$IF_NAME" ];then
		local IF_NAME=$(nvram get wan0_gw_ifname)
	fi

	if [ ! -z "$(nvram get wan0_pppoe_ifname)" ];then
		local IF_NAME="$(nvram get wan0_pppoe_ifname)"		# PPPoE
	fi

	echo $IF_NAME

}
Script_alias() {

        if [ "$1" == "create" ];then
            # Create alias 'suricata_manager' for '/jffs/addons/unbound/suricata_manager.sh'  # v1.22
            rm -rf "/opt/bin/suricata_manager" 2>/dev/null                                   # v2.01
            if [ -d "/opt/bin" ] && [ ! -L "/opt/bin/suricata_manager" ]; then
                echo -e $cBGRE"Creating 'suricata_manager' alias" 2>&1
                ln -s /jffs/addons/suricata/suricata_manager.sh /opt/bin/suricata_manager    # v2.00 v1.04
            fi
        else
            # Remove Script alias - why?
            echo -e $cBCYA"Removing 'suricata_manager' alias" 2>&1
            rm -rf "/opt/bin/suricata_manager" 2>/dev/null
        fi
}
_quote() {
  echo $1 | sed 's/[]\/()$*.^|[]/\\&/g'
}
Check_GUI_NVRAM() {

		local ERROR_CNT=0
		local ENABLED_OPTIONS=" "

		if [ "$1" == "active" ];then
			STATUSONLY="StatusOnly"
		else
			echo -e $cBCYA"\n\tRouter Configuration recommended pre-reqs status:\n" 2>&1

			if [ "$(Is_HND)" == "N" ] && [ "$(Is_AX)" == "N" ];then
				echo -e $cBRED"\a\t[✖] Warning ${cRESET}Router $HARDWARE_MODEL$cBRED isn't fully supported ${cBGRE}(Only HND-models RT-AC86U,RT-AX88U or RT-AX56U,RT-AX58U)"$cRESET
				ERROR_CNT=$((ERROR_CNT + 1))
			fi

			# Check GUI 'TrendMicro'
			[ "$(nvram get TM_EULA)" == "1" ] && { echo -e $cBRED"\a\t[✖] ***ERROR TrendMicro ENABLED $cRESET \t\t\t\tsee $HTTP_TYPE://$(nvram get lan_ipaddr):$HTTP_PORT/Advanced_Privacy.asp ->Administration Privacy"$cRESET 2>&1; ERROR_CNT=$((ERROR_CNT + 1)); } || echo -e $cBGRE"\t[✔] TrendMicro DISABLED" 2>&1

			# QoS
			[ "$(nvram get qos_enable)" == "1" ] && { echo -e $cBRED"\a\t[✖] ***ERROR QoS ENABLED $cRESET \t\t\t\t\tsee $HTTP_TYPE://$(nvram get lan_ipaddr):$HTTP_PORT/QoS_EZQoS.asp ->QoS - QoS to configuration"$cRESET 2>&1; ERROR_CNT=$((ERROR_CNT + 1)); } || echo -e $cBGRE"\t[✔] QoS DISABLED" 2>&1

			# Check Skynet
			[ -f /jffs/scripts/firewall ] && echo -e $cBRED"\a\t[✖] ***Warning Skynet installed" || echo -e $cBGRE"\t[✔] Skynet not Installed" 2>&1

			echo -e $cBCYA"\n\tOptions:${TXT}$DESC\n" 2>&1

		fi



		if [ -f /opt/etc/suricata/suricata.yaml ];then

			:

		fi

		local TXT=
		unset $TXT
		#echo -e $cRESET 2>&1

		if [ -z "$STATUSONLY" ];then
			[ $ERROR_CNT -ne 0 ] && { return 1; } || return 0
		else
			return 0
		fi
}

#=============================================Main=============================================================
# shellcheck disable=SC2068
Main() { true; } # Syntax that is Atom Shellchecker compatible!

ANSIColours

[ ! -L "/opt/bin/suricata_manager" ] && Script_alias "create"

FIRMWARE=$(echo $(nvram get buildno) | awk 'BEGIN { FS = "." } {printf("%03d%02d",$1,$2)}')
HARDWARE_MODEL=$(Get_Router_Model)

# Global Router URL
HTTP_TYPE="http"
HTTP_PORT=$(nvram get http_lanport)
[ "$(nvram get http_enable)" == "1" ] && { HTTP_TYPE="https"; HTTP_PORT=$(nvram get https_lanport) ; }


# Need assistance ?
if [ "$1" == "-h" ] || [ "$1" == "help" ];then
	clear                                                   # v1.21
	echo -e $cBWHT
	ShowHelp
	echo -e $cRESET
	exit 0
fi

if [ "$1" == "debug" ];then                                                          # v3.10
   DEBUGMODE="$(echo -e ${cRESET}$cWRED"Debug mode enabled"$cRESET)"
   shift
   set +x
fi

echo -e $cRESET"\n"$VER" Suricata IDS/IPS Manager.....\n"

case "$1" in
	install)

		ACTION="Install"

		Check_GUI_NVRAM "install"
		if [ $? -gt 0 ];then
			echo -e $cRESET"\n\tThe router does not currently meet ALL of the recommended pre-reqs as shown above."
			echo -e "\tHowever, whilst they are recommended, you may proceed with the suricata ${cBGRE}${ACTION}$cRESET"
			echo -e "\tas the recommendations are NOT usually FATAL if they are NOT strictly followed.\n"

			echo -e "\tPress$cBGRE Y$cRESET to$cBGRE continue suricata $ACTION $cRESET or press$cBRED [Enter] to ABORT"$cRESET
			read -r "CONTINUE_INSTALLATION"
			[ "$CONTINUE_INSTALLATION" != "Y" ] && { echo -e $cBRED"\a\n\tsuricata $ACTION CANCELLED!....."$cRESET; return 1; }  # v2.06
		fi

		echo -e $cBGRA

		opkg update
		opkg install suricata

		mkdir /opt/var/lib/suricata/ 2>/dev/null
		mkdir /jffs/addons/suricata/ 2>/dev/null

		FN="/opt/etc/suricata/suricata.yaml"

		curl --progress-bar -o $FN https://raw.githubusercontent.com/rgnldo/knot-resolver-suricata/master/suricata.yaml

		# Customise 'suricata.yaml'

		#    HOME_NET: "[192.168.0.0/24]"
		LANIPADDR=$(nvram get lan_ipaddr)
		LAN_SUBNET=${LANIPADDR%.*}
		LAN_CIDR=$(_quote "$(echo -e "[$LAN_SUBNET.0/24]")")
		sed -i "/HOME_NET:/ s/[^ ]*[^ ]/\\\"$LAN_CIDR\\\"/2" $FN

		#    DNS_SERVERS: "[192.168.1.1]"
		DNS_IP=$(echo "$(nvram get wan0_dns)" | awk '{print $1}')		# Beware wan0_dns will usually be two IP's
		#[ -n "$(pidof unbound)" ] && DNS=$(nvram get lan_ipadd_rt)
		DNS_IP="127.0.0.1"
		DNS=$(_quote "$(echo -e "[$DNS_IP]")")
		sed -i "/DNS_SERVERS:/ s/[^ ]*[^ ]/\\\"$DNS\\\"/2" $FN

		#    af-packet:
		#     - interface: ## set your wan interface
		WAN_IF=$(Get_WAN_IF_Name)
		sed -i "s/interface:.*set your wan interface/interface: $WAN_IF/" $FN

		# Download
		curl --progress-bar -o /opt/etc/init.d/S82suricata https://raw.githubusercontent.com/rgnldo/knot-resolver-suricata/master/S82suricata
		chmod +x /opt/etc/init.d/S82suricata

		mkdir /opt/var/lib/suricata/rules 2>/dev/null
		curl --progress-bar -o /opt/etc/suricata/classification.config https://rules.emergingthreats.net/open/suricata-4.0/rules/classification.config

		curl --progress-bar -SL https://rules.emergingthreats.net/open/suricata-4.0/emerging.rules.tar.gz | tar -zxC /opt/var/lib/suricata/
		/opt/etc/init.d/S82suricata restart


		FN="/opt/var/lib/suricata/rules/upd_rules_suricata.sh"
		cat > $FN << EOF
#! /bin/sh
logger "Updating:suricata rules..."

/opt/etc/init.d/S82suricata stop

curl -o /opt/etc/suricata/classification.config https://rules.emergingthreats.net/open/suricata-4.0/rules/classification.config
curl -SL https://rules.emergingthreats.net/open/suricata-4.0/emerging.rules.tar.gz | tar -zxC /opt/var/lib/suricata/

logger "Updating:suricata starting..."
sleep 10s
/opt/etc/init.d/S82suricata start
EOF
		chmod +x $FN >/dev/null

		# Create 03:00 Daily cron job to update the rules
		if [ ! -f /jffs/scripts/services-start ];then
			echo -e "#!/bin/sh\n" > /jffs/scripts/services-start
			chmod +x /jffs/scripts/services-start
		fi
		[ -z "$(grep "suricata" /jffs/scripts/services-start)" ] && echo -e "cru a suricata_updte \"0 3 * * * $FN\"" >> /jffs/scripts/services-start
		cru a suricata_updte "0 3 * * * $FN"

		# Perform a test compile of the config
		suricata -T

		#cat /opt/var/log/suricata/suricata.log
		;;
	stop)
		/opt/etc/init.d/S82suricata stop
		;;
	start)
		/opt/etc/init.d/S82suricata start
		;;
	logs)
	    echo -e $cBMAG"\tLog watch\t\t${cBGRE}Press CTRL-C to stop\n"$cRESET
	    EVELOG=$(ls -lah /opt/var/log/suricata/eve-* | tail -n 1 | awk '{print $NF}')
		tail -f /opt/var/log/suricata/fast.log /opt/var/log/suricata/stats.log $EVELOG # recommended
		;;
	config|configx)
	    [ "$1" == "config" ] && ACCESS="--view" || ACCESS="--unix"
		PRE_MD5="$(md5sum /opt/etc/suricata/suricata.yaml | awk '{print $1}')"
		nano $ACCESS /opt/etc/suricata/suricata.yaml
		# Has the user edited 'suricata.yaml'.....
		if [ "$ACCESS" == "--unix" ];then
		   POST_MD5="$(md5sum /opt/etc/suricata/suricata.yaml | awk '{print $1}')"
		   if [ "$PRE_MD5" != "$POST_MD5" ];then
			  echo -e "\nDo you want to restart suricata to apply your config changes?\n\n\tReply$cBRED 'y' ${cBGRE}or press [Enter] $cRESET to skip"
			  read -r "ANS"
			  [ "$ANS" == "y" ] && /opt/etc/init.d/S82suricata restart
		   fi
		fi
	    ;;
	test)
		curl http://testmyids.com/
		;;
	uninstall|remove)
		[ -f /opt/etc/init.d/S82suricata ] && /opt/etc/init.d/S82suricata stop
		[ -n "$(opkg list-installed | grep suricata)" ] && opkg --force-remove --force-depends remove suricata
		cru d suricata_updte
		sed -i '/suricata/d' /jffs/scripts/services-start
		Script_alias
		rm -rf /opt/var/lib/suricata 2>/dev/null
		rm /opt/etc/init.d/S82suricata 2>/dev/null
		rm -rf /opt/var/log/suricata/ 2>/dev/null
		rm -rf /opt/etc/suricata/ 2>/dev/null
		rm -rf /jffs/addons/suricata/ 2>/dev/null
		;;
	syntax|check)
		# Perform a test compile of the config
		suricata -T
		;;
	*)
		Check_GUI_NVRAM
		;;
esac