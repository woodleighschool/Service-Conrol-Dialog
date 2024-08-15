#!/bin/bash

if [ ! -f /usr/local/bin/dialog ]; then
	exit 1 # Dialog is not installed
fi

##
# Defaults
##

supersecretpassword="letmein"

JSONFile=$(mktemp -u /var/tmp/dialogJSONFile.XXX)
commandFile=$(mktemp -u /var/tmp/dialogCommandFile.XXX)

loggedInUser=$(stat -f%Su /dev/console)
loggedInUserID=$(id -u "${loggedInUser}")

##
# Functions
##

function dialogUpdate() {
	echo "$1" >>"${commandFile}"
}

# https://github.com/dan-snelson/Setup-Your-Mac/blob/465074f8f5eff793270534ed2e9d4e6c96b00ab9/Setup-Your-Mac-via-Dialog.bash#L1765-L1772
function get_json_value() {
	for var in "${@:2}"; do jsonkey="${jsonkey}['${var}']"; done
	JSON="$1" osascript -l 'JavaScript' \
		-e 'const env = $.NSProcessInfo.processInfo.environment.objectForKey("JSON").js' \
		-e "JSON.parse(env)$jsonkey"
}

function cleanup() {
	rm -f "${JSONFile}"
	rm -f "${commandFile}"
}

function manage_services() {
	# Map start|stop to bootout|bootstrap
	local action=$([[ $1 == "start" ]] && echo "bootstrap" || echo "bootout")
	echo "action: ${action} ${2}"

	case $2 in
	jamf)
		system_plists=("/Library/LaunchDaemons/com.jamf.management.daemon.plist" "/Library/LaunchDaemons/com.jamfsoftware.task.1.plist")
		gui_plists=("/Library/LaunchAgents/com.jamf.management.agent.plist")
		;;
	sophos)
		system_plists=("/Library/LaunchDaemons/com.sophos.common.servicemanager.plist" "/Library/LaunchDaemons/com.sophos.sophoscbr.plist")
		gui_plists=("/Library/LaunchAgents/com.sophos.user.agent.plist")
		sophos_services=("com.sophos.webd.ne" "com.sophos.webd" "com.sophos.cryptoguard" "com.sophos.scan" "com.sophos.devicecontrol" "com.sophos.evmon" "com.sophos.mcs" "com.sophos.livequery" "com.sophos.shs" "com.sophos.notification" "com.sophos.configuration" "com.sophos.updater" "com.sophos.cleand")
		;;
	connect)
		system_plists=("/Library/LaunchDaemons/fz-system-service.plist")
		gui_plists=("/Library/LaunchAgents/com.familyzone.filterclient.agent.plist")
		;;
	esac

	# Perform action for system plists
	for sys_service in "${system_plists[@]}"; do
		launchctl "${action}" system "${sys_service}"
	done

	# Perform action for gui plists
	for user_service in "${gui_plists[@]}"; do
		launchctl "${action}" "gui/${loggedInUserID}" "${user_service}"
	done

	# Additional actions for Sophos and Connect services
	if [[ $2 == "sophos" && "${action}" == "bootout" ]]; then
		for service in "${sophos_services[@]}"; do
			launchctl "${action}" system/"${service}"
		done
	fi

	[[ $2 == "connect" && "${action}" == "bootout" ]] && launchctl asuser "${loggedInUserID}" killall JavaAppLauncher

	sleep 3
}

##
# Display Password Access Dialog
##

if [[ ! "${loggedInUser}" =~ ^(woodmin|tokenadmin)$ ]]; then
	passwordCorrect=false
	while [ "${passwordCorrect}" = false ]; do
		# Updated message with Markdown formatting
		message="Please enter the password to use this utility."

		if [ "${passwordIncorrect}" = true ]; then
			message="**Password Incorrect, please try again.**\n\n_This event has been logged._"
		fi

		# JSON for the dialog
		dialogJSON='
{
  "commandfile": "'"${commandFile}"'",
  "title": "Password Required",
  "message": "'"${message}"'",
  "icon": "sf=lock.fill",
  "button1text": "Continue",
  "button2text": "Cancel",
  "textfield": [
    {
      "title": "Password",
      "secure": true,
      "required": true
    }
  ],
  "quitkey": ".",
  "height": "250",
  "width": "625"
}'

		echo "${dialogJSON}" >"${JSONFile}"
		results=$(eval dialog --jsonfile "${JSONFile}" --json)

		# Evaluate User Input
		if [[ -z "${results}" ]]; then
			returnCode="2"
		else
			returnCode="0"
		fi

		case "${returnCode}" in
		0) # Continue Button
			password=$(get_json_value "$results" "Password")
			if [ "${password}" == "${supersecretpassword}" ]; then
				passwordCorrect=true
			else
				echo "Incorrect Password Entered (${password})"
				passwordIncorrect=true
			fi
			;;
		*) # Catch all (Cancel Button)
			cleanup
			exit 0
			;;
		esac
	done
fi

##
# Display Service Control Dialog
##

# Probe plist's to determine whether app is installed
[[ -f "/Library/LaunchAgents/com.sophos.user.agent.plist" ]] && disableSophos="false"
[[ -f "/Library/LaunchAgents/com.jamf.management.agent.plist" ]] && disableJamf="false"
[[ -f "/Library/LaunchAgents/com.familyzone.filterclient.agent.plist" ]] && disableConnect="false"

while true; do
	# Check if the service is running and set the 'checked' switch
	sophosRunning=$(ps aux | grep "SophosAntiVirus" | grep -v "grep" &>/dev/null && echo "true" || echo "false")
	jamfRunning=$(ps aux | grep "JamfDaemon" | grep -v "grep" &>/dev/null && echo "true" || echo "false")
	connectRunning=$(ps aux | grep '/usr/bin/open -W /Applications/FamilyZone/MobileZoneAgent/bin/Connect.app' | grep -v "grep" &>/dev/null && echo "true" || echo "false")

	# JSON for the dialog
	dialogJSON='
{
  "commandfile": "'"${commandFile}"'",
  "title": "Service Manager",
  "message": "Enable/Disable services here, then press `Update` to apply the change.\n\n**Cancelling enables all services.**",
  "icon": "none",
  "button1text": "Update",
  "button2text": "Cancel",
  "checkbox": [
    {
      "label": "Sophos",
      "checked": "'"${sophosRunning}"'",
      "disabled": "'"${disableSophos:-true}"'",
      "icon": "https://r2-d2.woodleigh.vic.edu.au/Icons/Sophos.png"
    },
    {
      "label": "Jamf",
      "checked": "'"${jamfRunning}"'",
      "disabled": "'"${disableJamf:-true}"'",
      "icon": "https://r2-d2.woodleigh.vic.edu.au/Icons/Jamf.png"
    },
    {
      "label": "Linewize Connect",
      "checked": "'"${connectRunning}"'",
      "disabled": "'"${disableConnect:-true}"'",
      "icon": "https://r2-d2.woodleigh.vic.edu.au/Icons/LinewizeConnect.png"
    }
  ],
  "checkboxstyle": {
    "style": "switch",
    "size": "large"
  },
  "moveable": "true",
  "quitkey": ".",
  "height": "400",
  "width": "400"
}'

	echo "${dialogJSON}" >"${JSONFile}"
	results=$(eval dialog --jsonfile "${JSONFile}" --json) # display dialog

	# display processing dialog
	dialog --icon "sf=gearshape.fill,animation=pulse" --mini --title "none" --message "Modifying Services" --progress &
	sleep 0.3
	until pgrep -q -x "Dialog"; do
		sleep 0.5
	done

	# Evaluate User Input
	if [[ -z "${results}" ]]; then
		returnCode="2"
	else
		returnCode="0"
	fi

	case "${returnCode}" in
	0) # Update Button
		sophosSwitch=$(get_json_value "$results" "Sophos")
		jamfSwitch=$(get_json_value "$results" "Jamf")
		connectSwitch=$(get_json_value "$results" "Linewize Connect")

		# Logic for Sophos
		if [[ ${disableSophos} == "false" ]]; then
			if [[ ${sophosSwitch} == "true" && ${sophosRunning} == "false" ]]; then
				manage_services start sophos
			elif [[ ${sophosSwitch} == "false" && ${sophosRunning} == "true" ]]; then
				manage_services stop sophos
			fi
		fi

		# Logic for Jamf
		if [[ ${disableJamf} == "false" ]]; then
			if [[ ${jamfSwitch} == "true" && ${jamfRunning} == "false" ]]; then
				manage_services start jamf
			elif [[ ${jamfSwitch} == "false" && ${jamfRunning} == "true" ]]; then
				manage_services stop jamf
			fi
		fi

		# Logic for Linewize Connect
		if [[ ${disableConnect} == "false" ]]; then
			if [[ ${connectSwitch} == "true" && ${connectRunning} == "false" ]]; then
				manage_services start connect
			elif [[ ${connectSwitch} == "false" && ${connectRunning} == "true" ]]; then
				manage_services stop connect
			fi
		fi
		;;
	*) # Catch all (Cancel Button)
		# Restart all services if they are stopped and installed
		[[ ${disableSophos} == "false" && ${sophosRunning} == "false" ]] && manage_services start sophos
		[[ ${disableJamf} == "false" && ${jamfRunning} == "false" ]] && manage_services start jamf
		[[ ${disableConnect} == "false" && ${connectRunning} == "false" ]] && manage_services start connect

		break
		;;
	esac
	# kill processing dialog
	killall Dialog &>/dev/null
done

# Cleanup temporary files
killall Dialog &>/dev/null
cleanup
