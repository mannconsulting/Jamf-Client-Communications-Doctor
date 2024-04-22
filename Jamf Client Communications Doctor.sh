#!/bin/zsh
###############################################################################
# Name:     Jamf Client Communications Doctor
# Creator:  Mann Consulting
# Summary:  Monitors and repairs Jamf Client Communications
##
# More info: https://mann.com/jamf/doctor
#
# Note:     This script is part of Mann Consulting's Jamf Pro Workflows subscription and is made available free to the public with no guarantees
#           or support.  Mann Consulting is not responsible for data loss or other damages caused by use of this script.
#           Redistribution or commercial use without including this header is prohibited.
#           If you'd like updates or support sign up at https://mann.com/jamf or email support@mann.com for more details
###############################################################################
readonly SCRIPT_PATH="${0}"
readonly VERSIONDATE=20240422
readonly APPLICATION=JamfClientCommunicationsDoctor

LOGGING=INFO
POLICY_KILL_THRESHOLD=850
EA_KILL_THRESHOLD=60
caffeinateJamf=yes
caffeinateTimer=54834

### Start Public Logging Public - 20230816
#
# Logging Levels
# ERROR - Only fatal errors
# WARN - Fatal errors and warnings
# INFO - All messages, no user identifiable data
# DEBUG - Debug logging may inclue user identifiable data.
#
# SESSIONID
# Randomly generated number for this session.

JSSURL=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
jamfVarJSSID=0

readonly SESSIONID=${jamfVarJSSID}-$RANDOM
declare -rA levels=(DEBUG 0 INFO 1 WARN 2 ERROR 3)

printlog() {
  [[ -z "$2" ]] && 2=INFO
  log_message=$1
  log_priority=$2
  timestamp=$(date +%F\ %T)

  if [[ ${levels[$log_priority]} -ge ${levels[$LOGGING]} ]]; then
    while IFS= read -r logmessage; do
      echo "$timestamp" "${log_priority} : $JSSURL : $APPLICATION : $VERSIONDATE : $SESSIONID : ${logmessage}"
    done <<< "$log_message"
  fi
}

deduplicatelogs() {
  loginput=${1:-"Log"}
  logoutput="$loginput"
}
### End Public Logging

installNeeded() {
  local -r myHash=$(shasum -a 256 "${SCRIPT_PATH}" | awk '{print $1}')
  local -r installedPath="/Library/Application Support/Mann/Scripts/Jamf Client Communications Doctor.sh"
  if [[ ! -x "${installedPath}" ]]; then
    printlog "${APPLICATION} script is not installed" INFO
    return 0
  elif [[ "${myHash}" != $(shasum -a 256 "/Library/Application Support/Mann/Scripts/Jamf Client Communications Doctor.sh" | awk '{print $1}') ]]; then
    printlog "${APPLICATION} script is not up-to-date" INFO
    return 0
  elif ! launchctl print system/com.mann.JamfClientCommunicationsDoctor >/dev/null 2>&1; then
    printlog "${APPLICATION} launchd is not found in the system target" WARN
    return 0
  else
    return 1
  fi
}

caffeinateKill() {
  if pgrep -fq "caffeinate -s -t ${caffeinateTimer}"; then
    printlog "caffeinate command found, killing" INFO
    pkill -f "caffeinate -s -t ${caffeinateTimer}"
  fi
}

installScript() {
  local -r scriptPath="/Library/Application Support/Mann/Scripts/Jamf Client Communications Doctor.sh"

  if ! [[ -d "/Library/Application Support/Mann/Scripts" ]]; then
    mkdir -p "/Library/Application Support/Mann/Scripts"
    chown root:admin "/Library/Application Support/Mann/Scripts"
    chmod 755 "/Library/Application Support/Mann/Scripts"
  fi

  touch "${scriptPath}"
  chmod 700 "${scriptPath}"
  chown root:wheel "${scriptPath}"
  cat "${SCRIPT_PATH}" > "${scriptPath}"
}

installLaunchd() {
  local -r launchdPath="/Library/LaunchDaemons/com.mann.JamfClientCommunicationsDoctor.plist"
  local -r launchdContents=$(cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mann.JamfClientCommunicationsDoctor</string>
    <key>ProgramArguments</key>
    <array>
      <string>/Library/Application Support/Mann/Scripts/Jamf Client Communications Doctor.sh</string>
    </array>
    <key>StandardErrorPath</key>
    <string>/var/log/JamfClientCommunicationsDoctor.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/JamfClientCommunicationsDoctor.log</string>
    <key>WatchPaths</key>
    <array>
      <string>/Library/Application Support/JAMF/tmp</string>
    </array>
    <key>StartInterval</key>
    <integer>86400</integer>
    <key>RunAtLoad</key>
		<true/>
</dict>
</plist>
EOF
)

  if launchctl print system/com.mann.JamfClientCommunicationsDoctor >/dev/null 2>&1; then
    printlog "LaunchDaemon is currently loaded in the system target, removing it before loading a new one." INFO
    launchctl bootout system "${launchdPath}" >/dev/null 2>&1
  fi

  touch "${launchdPath}"
  chown root:wheel "${launchdPath}"
  chmod 644 "${launchdPath}"
  printf "%s" "${launchdContents}" >"${launchdPath}"
  launchctl bootstrap system "${launchdPath}"
}

round() {
  echo $(printf %.$2f $(echo "scale=$2;(((10^$2)*$1)+0.5)/(10^$2)" | bc))
}

fixBlockingInstallers() {
  installerProcesses=($(pgrep -x -d " " installer))
  installerCommands=$(ps -ao "etime command" | grep installer)
  deduplicatelogs "$installerCommands"
  printlog "Installer processes found: $logoutput" WARN
  for i in $installerProcesses; do
    installerDetails=$(ps -o "pid etime command" -p $i | tail +2)
    printlog "Checking process $installerDetails" INFO
    installMonitorPID=$(cat /private/var/run/installd.commit.pid)
    etime=$(ps -ao etime= $i)
    printlog "Process etime is $etime" INFO
    if [[ $etime == *"-"* ]]; then
      days=$(ps -ao etime= $i | cut -d "-" -f1)
      printlog "Process days is $days"
    else
      printlog "Process isn't older than a day" INFO
      continue
    fi
    if [[ $days -ge 1 ]]; then
      printlog "Found Blocking Installer Running for $days days at $installerDetails killing all" ERROR
      killall -9 installer
      killall -9 package_script_service
      killall -9 installd
      killall -9 install_monitor
      return
    fi
  done
}

list_descendants() {
  local children=( $(pgrep -P "$1" 2>&1) )
  local realOutput=""

  for pid in $children
  do
    output=$(list_descendants "$pid" | tr -d $'\n')
    if [[ ! -z "${output}" ]]; then
      # grand-kids then parent of grand-kids (?)
      [[ -z "${realOutput}" ]] && realOutput="${output} $pid" || realOutput="${realOutput} ${output} $pid"
    else
      [[ -z "${realOutput}" ]] && realOutput="$pid" || realOutput="${realOutput} $pid"
    fi
  done
  echo "$realOutput"
}

getJamfPid() {
  local -r jamfPid=$(ps ax -o pid,command | grep jamf | grep -E 'policy|recon' | grep -v grep | awk '{print $1}')
  printf "%s" "${jamfPid}"
}

getJamfSubcommandScriptPath() {
  local -r fullCommand="$1"
  if [[ "${fullCommand}" =~ '(/Library/Application Support/JAMF/tmp/[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-)([A-Z0-9]{12})' ]]; then
    printf "%s" "${matches[1]}"
  else
    echo -n ""
  fi
}

getJamfSubcommandType() {
  local -r fullCommand="$1"
  if [[ "${fullCommand}" =~ '(/Library/Application Support/JAMF/tmp/[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-)([A-Z0-9]{12})$' ]]; then
    printf "%s" "extension-attribute"
  else
    printf "%s" "policy"
  fi
}

getJamfSubcommandThreshold() {
  local -r file="$1"
  local -r type="$2"
  if [[ "${type}" == "extension-attribute" ]]; then
    printf "%d" "${EA_KILL_THRESHOLD}"
  else # Policy
    inbuiltThreshold=${POLICY_KILL_THRESHOLD}
    printf "%d" "${inbuiltThreshold}"
  fi
}

jamfLaunchDaemonCheck() {
  if [[ -f /Library/LaunchDaemons/com.jamfsoftware.task.1.plist ]] && [[ -f /Library/LaunchDaemons/com.jamf.management.daemon.plist ]]; then
    printlog "Jamf LaunchDaemon found" DEBUG
  else
    printlog "Jamf LaunchDaemon missing, refreshing management framework" ERROR
    jamfManageOutput=$(jamf manage -verbose 2>&1)
    deduplicatelogs $jamfManageOutput
    printlog "Jamf Management Framework Refreshed: ${logoutput}" INFO
  fi
  taskLabel=$(cat /Library/LaunchDaemons/com.jamfsoftware.task.1.plist | grep com.jamfsoftware.task | cut -d '>' -f 2 | cut -d '<' -f 1)
  launchctlOutput=$(launchctl print "system/${taskLabel}")
  launchctlStatus=$?
  if [[ $launchctlStatus != 0 ]]; then
    printlog "Jamf LaunchDaemon not loaded, restarting" ERROR
    startJamfLaunchDaemon
  fi

  launchctlOutput=$(launchctl print "system/com.jamf.management.daemon")
  launchctlStatus=$?
  if [[ $launchctlStatus != 0 ]]; then
    printlog "Jamf Daemon not loaded, restarting" ERROR
    startJamfLaunchDaemon
  fi
}

parseProfile() {
  local mannPlistPath="/Library/Managed Preferences/$1"
  local refreshPlist="$2"
  if [[ $refreshPlist == "refresh" ]]; then
    printlog "Refreshing Jamf User Data" INFO
    touch "/Library/Application Support/JAMF/JamfUserDataRefresh"
    /usr/local/bin/jamf recon
    until ! [[ -f ${mannPlistPath} ]]; do
      sleep 2
      loopcomplete=$((loopcomplete+1))
      if [[ $loopcomplete -ge 150 ]]; then
        printlog "Userdata refresh taking too long"
      fi
    done
    rm "/Library/Application Support/JAMF/JamfUserDataRefresh"
    sleep 60
    /usr/local/bin/jamf recon
    until [[ -f ${mannPlistPath} ]]; do
      sleep 2
      loopcomplete=$((loopcomplete+1))
      if [[ $loopcomplete -ge 150 ]]; then
        printlog "Userdata refresh taking too long, using stale data" INFO
        return
      fi
    done
  fi
  # Override variables using configuration profile
  if [[ -e "${mannPlistPath}" ]]; then
    SAVEIFS=$IFS   # Save current IFS (Internal Field Separator)
    IFS=$'\n'      # Change IFS to newline char
    local keys=( $(cat "${mannPlistPath}" | plutil -convert xml1 - -o - | xmllint --xpath '//key' - | sed -E 's/<\/key><key>/§/g; s/<\/?key>//g' | tr '§' '\n') )
    local values=( $(cat "${mannPlistPath}" | plutil -convert xml1 - -o - | xmllint --xpath '//key/following-sibling::*[1]' - | \
      sed -E 's/<true\/>/<bool>YES<\/bool>/g; s/<false\/>/<bool>NO<\/bool>/g; s/<([^\/]+)\/>|<([^\/]+)><\/\1>/<\1>EMPTY<\/\1>/g; s/<\/[^>]+><[^>]+>/§/g; s/<\/?[^>]+>//g' | tr '§' '\n') )
    local customConfigurationString=""

    local keyIndex
    for keyIndex in {1.."${#keys[@]}"}; do
      local key="${keys[$keyIndex]}"
      local value="${values[$keyIndex]}"
      if [[ "${value}" == "EMPTY" ]]; then
        continue
      fi
      # Put all the overrides into one variable for one printlog rather than multiple
      [[ -z "${customConfigurationString}" ]] && customConfigurationString="${key}=${value}" || \
        customConfigurationString="${customConfigurationString};${key}=${value}"
      export "${key}=${value}"
    done
    if (( ${#keys[@]} > 0 )); then
      printlog "Custom configuration profile settings for $1: ${customConfigurationString}" DEBUG
    fi
    unset customConfigurationString
    IFS=${SAVEIFS}
  fi
  unset mannPlistPath
}

restartJamfLaunchDaemon() {
  launchctl bootout system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  launchctl bootout system /Library/LaunchDaemons/com.jamf.management.daemon.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamf.management.daemon.plist
}

startJamfLaunchDaemon() {
  launchctl bootout system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  launchctl bootout system /Library/LaunchDaemons/com.jamf.management.daemon.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamf.management.daemon.plist
}

trimLog() {
  if [[ $(wc -c "${1}" | xargs | cut -d ' ' -f 1 ) -ge 10485760 ]]; then
    trimmedLog=$(tail -c 5485760 "${1}")
    echo "$trimmedLog" >"${1}"
  fi
}

uninstallOld() {
  if [[ -f "/Library/LaunchDaemons/com.mann.KillLongRunningPoliciesOrEAs.plist" ]] || [[ -f "/Library/Application Support/Mann/Kill Long Running Policies and EAs.sh" ]] || [[ -f "/Library/LaunchDaemons/com.mann.KillPolicyEA.plist" ]]; then
    printlog "Uninstalling Old Files" INFO
    launchctl unload "/Library/LaunchDaemons/com.mann.KillLongRunningPoliciesOrEAs.plist"
    launchctl unload "/Library/LaunchDaemons/com.mann.KillPolicyEA.plist"
    rm /Library/LaunchDaemons/com.mann.KillPolicyEA.plist
    rm "/Library/LaunchDaemons/com.mann.KillLongRunningPoliciesOrEAs.plist"
    rm "/Library/Application Support/Mann/Kill Long Running Policies and EAs.sh"
    rm "/Library/Application Support/Mann/Scripts/Kill Long Running Policies and EAs.sh"
  fi
}

# Start Main
trimLog /var/log/JamfClientCommunicationsDoctor.log
parseProfile com.mann.JamfClientCommunicationsRepair.plist

[[ -n "${1}" && -n "${2}" ]] && invokedByJamf=1 || invokedByJamf=0;

if [[ $invokedByJamf -eq 1 ]]; then
  # Invoked by Jamf
  if installNeeded; then
    printlog "Install needed, installing Script & LaunchDaemon" INFO
    installScript
    installLaunchd
    uninstallOld
    printlog "Installed Successfully"
  else
    printlog "Install/Upgrade not necessary, exiting" WARN
    exit 0
  fi
else
  # Not invoked by Jamf (running as launchd)
  jamfPid=$(getJamfPid)

  if [[ -z "${jamfPid}" ]]; then
    printlog "Failed to get jamf PID, exiting" WARN
    exit 2
  fi
  jamfCommand=$(ps -o command= ${jamfPid})
  printlog "jamfCommand is ${jamfCommand}" DEBUG

  if [[ ${caffeinateJamf:l} == "yes" ]]; then
    printlog "Caffeinate set to yes, Caffeinating the process" DEBUG
    caffeinate -s -t ${caffeinateTimer} -w ${jamfPid} &
    caffeinatePID=$!
  fi

  # Begin Cleanup Loop
  while true; do
    etime=$(ps -ao etime= ${jamfPid})
    printlog "Process etime is $etime" DEBUG
    if [[ $etime == *"-"* ]]; then
      days=$(ps -ao etime= ${jamfPid} | cut -d "-" -f1)
      printlog "Jamf Policy running for $days days." DEBUG
    else
      printlog "Jamf Policy isn't older than a day." DEBUG
    fi
    if [[ $days -ge 2 ]]; then
      printlog "Jamf Policy running for more than 2 days, killing and refreshing LaunchDaemon" ERROR
      killall jamf
      restartJamfLaunchDaemon
    fi

    IFS=$'\n'
    jamfChildren=( $(pgrep -aP $jamfPid) )
    if ! ps -p $jamfPid > /dev/null 2>&1 ; then
      printlog "Jamf process gone, exiting." DEBUG
      caffeinateKill
      exit 0
    fi

    if [[ -n $jamfChildren ]]; then
      printlog "Found ${#jamfChildren[@]} jamf child processes" DEBUG
      printlog "jamfChildren is '${jamfChildren[@]}' (count ${#jamfChildren[@]})" DEBUG
      for child in "${jamfChildren[@]}"; do
        [[ -z "${child}" ]] && continue;
        printlog "Child pid is '${child}'" DEBUG
        local childCommand="$(ps -o command= ${child})"
        local childFile="$(echo ${childCommand/*\/Library/\/Library} | cut -d "'" -f2)"
        printlog "childCommand is '${childCommand}'" DEBUG
        printlog "childFile is '${childFile}'" DEBUG
        local childType=$(getJamfSubcommandType "${childCommand}")
        local KILL_THRESHOLD=$(getJamfSubcommandThreshold "${childFile}" ${childType})
        if [[ "${childType}" == "extension-attribute" || "${childType}" == "policy" ]]; then
          if [[ ${+runningChildren[$child]} == 1 ]]; then
            runningChildren[$child]=$(( ${runningChildren[$child]} + 1))
            printlog "Child ${childType} at $child has been running for ${runningChildren[$child]} minutes ($KILL_THRESHOLD max)" DEBUG
            if (( ${runningChildren[$child]} >= $KILL_THRESHOLD )); then
              childContents=$(head -10 "${childFile}" | awk '{printf "%s\\n", $0}')
              children=($(list_descendants "$child"))
              childrenNames=$(ps -x -p $children[@] | awk '{printf "%s\\n", $0}')
              if [[ -z $childrenNames ]]; then
                printlog "Unable to get children Names, trying to be more Verbose." WARN
                childrenNames=$(ps -x -o "pid=ProcessID ppid=ParentID etime=ElapsedTime command=Command" -p $children[@])
              fi
              if [[ -z $childrenNames ]]; then
                printlog "Unable to get children Names, just listing everything." WARN
                childrenNames=$(ps -x -o "pid=ProcessID ppid=ParentID etime=ElapsedTime command=Command")
              fi
              deduplicatelogs $childrenNames
              childrenNames="${logoutput}"
              echo $(date "+%Y-%m-%d %k:%M:%S") > "/Library/Application Support/JAMF/Last_Blocking_Policy_Date"
              echo "${logoutput}" "/Library/Application Support/JAMF/Last_Blocking_Policy_Child"
              printlog "Child ${childType} at $child has been running for longer than $KILL_THRESHOLD minutes. Killing the ${childType}. First 10 lines of ${childFile} for debugging:\n${childContents}\nChild Processes: ${childrenNames}" ERROR
              printlog "Killing parent $child" DEBUG
              kill -9 $child
              printlog "Killing children $children" DEBUG
              for i in $children[@]; do
                kill -9 ${i}
              done
              unset "runningChildren[${child}]"
            fi
          else
            printlog "Found ${childType} at pid $child, adding to watch-list" DEBUG
            runningChildren[$child]=0
          fi
        fi
      done
    fi
    printlog "Sleeping 1 minute before checking for more children" DEBUG
    sleep 60
  done
  if pgrep -x installer; then
    printlog "Installers found running, checking if blocking" DEBUG
    fixBlockingInstallers
  fi
  jamfLaunchDaemonCheck
  caffeinateKill
fi
