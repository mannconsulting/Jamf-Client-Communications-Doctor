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
readonly VERSIONDATE=20260331
readonly APPLICATION=JamfClientCommunicationsDoctor
LOGGING=INFO
POLICY_KILL_THRESHOLD=850
EA_KILL_THRESHOLD=60
caffeinateJamf=yes
caffeinateTimer=54834
##### Start Default Header 20251112
zmodload zsh/datetime
PATH="/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin"
scriptPath=${0}
currentUser=${$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }'):-UnknownUserName}
currentUserID=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/kCGSSessionUserIDKey :/ { print $3 }')
currentUserHome=$(dscl . -read Users/${currentUser} | grep ^NFSHomeDirectory | awk '{print $2}')
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
LogDateFormat="%Y-%m-%d %H:%M:%S"
starttime=$(strftime "$LogDateFormat")

### Start Logging 20251112
readonly jamfVarJSSID=$(defaults read "/Library/Managed Preferences/com.mann.jamfuserdata.plist" JSSID 2>/dev/null || echo 0)
readonly JSSURL=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null) \
         hostname=${hostname:-$(hostname)} \
         computername=${computername:-$(scutil --get ComputerName 2>/dev/null)} \
         serialnumber=${serialnumber:-$(ioreg -d2 -c IOPlatformExpertDevice | awk -F\" '/IOPlatformSerialNumber/{print $(NF-1)}')} \
         SESSIONID=${jamfVarJSSID}-$RANDOM
declare -rA levels=(DEBUG 0 INFO 1 WARN 2 ERROR 3)
LOGGING=${LOGGING-INFO} DATADOGLOGGING=${DATADOGLOGGING-INFO}

printlog() {
  [[ -z "$2" ]] && 2=INFO
  [[ -z "$1" ]] && return
  local log_message log insidelogrepeat=0 previous_line
  if [[ ${1//[$'\n']/} != "$1" ]]; then
    while read log; do
      if [[ $log == $previous_line ]]; then
        let insidelogrepeat=$insidelogrepeat+1
        continue
      fi
      previous_line="$log"
      if [[ $insidelogrepeat -gt 2 ]]; then
        log_message+="Last line repeated ${insidelogrepeat} more times\n"
        local insidelogrepeat=0
        log_message+="$log\n"
      fi
      log_message+="$log\n"
    done <<< "$1"
  else
    log_message=$1
  fi
  log_priority=$2
  local timestamp=$(strftime '%Y-%m-%d %H:%M:%S')
  local logLength=${#log_message}
  if [[ $logLength -ge 76000 ]]; then
    local leftOver=${log_message:76000}
    log_message=${log_message:0:75999}
  fi
  if [[ "$log_message" == "$previous_log_message" ]]; then
    ((logrepeat++)); return
  elif (( logrepeat > 0 )); then
    echo "$timestamp $previous_log_priority: Last message repeated $logrepeat more times"
    [[ -n "$DATADOGAPI" ]] && send_to_datadog "Last message repeated $logrepeat more times" "$previous_log_priority"
    logrepeat=0
  fi
  previous_log_message="$log_message"; previous_log_priority="$log_priority"
  [[ ${levels[$log_priority]:-0} -ge ${levels[$LOGGING]:-1} ]] && { echo "$timestamp $log_priority: $log_message"; logger -t "Mann-$APPLICATION" "Mann-$APPLICATION: $log_message" &|; }
  [[ -n "$DATADOGAPI" && ${levels[$log_priority]:-0} -ge ${levels[$DATADOGLOGGING]:-1} ]] && send_to_datadog "$log_message" "$log_priority"
  if [[ -n $leftOver ]]; then printlog $leftOver $log_priority; fi
}

send_to_datadog() {
  local msg="$1" level="$2"
  ((INDEX++))
  if [[ "${redaction:l}" != "disabled" ]]; then
    msg="${msg//${hostname:-PROTECTED_HOSTNAME}/PROTECTED_HOSTNAME}"
    msg="${msg//${computername:-PROTECTED_COMPUTERNAME}/PROTECTED_COMPUTERNAME}"
    msg="${msg//${serialnumber:-PROTECTED_SERIALNUMBER}/PROTECTED_SERIALNUMBER}"
    msg="${msg//${currentUser:-PROTECTED_USERNAME}/PROTECTED_USERNAME}"
    msg="${msg//${password:-PROTECTED_PASSWORD}/PROTECTED_PASSWORD}"
  fi
  msg="${msg//\"/\\\"}"
  msg="${msg//$'\n'/\\n}"
  curl -H "Content-Type: application/json" -H "DD-API-KEY: $DATADOGAPI" -m 15 -s \
       -X POST https://http-intake.logs.datadoghq.com/v1/input \
       -d "{\"message\":\"$msg\",\"level\":\"$level\",\"http.url\":\"$JSSURL\",\"application\":\"$APPLICATION\",\"version\":\"$VERSIONDATE\",\"index\":\"$INDEX\",\"env\":\"$SWVERSIONLONG\",\"sessionid\":\"$SESSIONID\"}" >/dev/null &|
}

jamfPrettyExit() {
  message=${1}
  message="${message//\//\\/}" # Escape forward slashes
  policyLogFile=$(ps -p $PPID | tail -1 | awk -F"'" '{print $(NF-1)}')
  if [[ -f "$policyLogFile" ]]; then
    sed -i '' '1s/^/\'$'\n/g' "$policyLogFile"
    sed -i '' '1s/^/####################################################\'$'\n/g' "$policyLogFile"
    sed -i '' '1s/^/'"${message//$'\n'/\\n}"'\'$'\n/g' "$policyLogFile"
    sed -i '' '1s/^/####################################################\'$'\n/g' "$policyLogFile"
    sed -i '' '1s/^/\'$'\n/g' "$policyLogFile"
  fi
}

cleanupAndExit() { # $1 = exit code, $2 message
  printlog "$2" $3
  jamfPrettyExit "$2"
  printlog "################## End $APPLICATION (took $((( (`strftime %s` - `date -jf $LogDateFormat $starttime +%s`) ))) seconds)" INFO
  exit "$1"
}

if [[ $lockedSeconds -gt 7200 ]]; then
  printlog "Computer has been locked for over 2 hours, using higher kill thresholds for hung policy protection." WARN
  POLICY_KILL_THRESHOLD=1700
  EA_KILL_THRESHOLD=180
fi

installNeeded() {
  local -r myHash=$(shasum -a 256 "${scriptPath}" | awk '{print $1}')
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

installScript() {
  local -r _scriptPath="/Library/Application Support/Mann/Scripts/Jamf Client Communications Doctor.sh"

  if ! [[ -d "/Library/Application Support/Mann/Scripts" ]]; then
    mkdir -p "/Library/Application Support/Mann/Scripts"
  fi

  chown root:admin "/Library/Application Support/Mann"
  chmod 755 "/Library/Application Support/Mann"
  chown root:admin "/Library/Application Support/Mann/Scripts"
  chmod 755 "/Library/Application Support/Mann/Scripts"

  touch "${_scriptPath}"
  chmod 755 "${_scriptPath}"
  chown root:wheel "${_scriptPath}"
  cat "${scriptPath}" > "${_scriptPath}"
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
  printlog "Installer processes found: $installerCommands" WARN
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
      printlog "Found Blocking Installer Running for $days days at $installerDetails killing all. The system has been locked for $(beenLockedSince) seconds." ERROR
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
    printlog "Jamf Management Framework Refreshed: ${jamfManageOutput}" INFO
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
  enableJamfCheckinTaskIfDisabled
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

enableJamfCheckinTaskIfDisabled() {
  local -r label=$(cat /Library/LaunchDaemons/com.jamfsoftware.task.1.plist | xmllint --xpath '//key[text()="Label"]/following-sibling::string[1]/text()' -)
  if launchctl print system | grep -q '"'"${label}"'"[[:space:]]*=>[[:space:]]*disabled'; then
    printlog "Found that Jamf's check-in task ${label} was disabled. This SHOULD NOT HAPPEN" ERROR
    launchctl enable "system/${label}"
    launchctl bootstrap system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  fi
}

restartJamfLaunchDaemon() {
  launchctl bootout system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  enableJamfCheckinTaskIfDisabled
  launchctl bootout system /Library/LaunchDaemons/com.jamf.management.daemon.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamf.management.daemon.plist
}

startJamfLaunchDaemon() {
  launchctl bootout system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jamfsoftware.task.1.plist
  enableJamfCheckinTaskIfDisabled
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
    printlog "Installed Successfully" INFO
  else
    printlog "Install/Upgrade not necessary, exiting" WARN
    exit 0
  fi
else

  jamfPid=$(getJamfPid)

  if [[ -z "${jamfPid}" ]]; then
    printlog "Failed to get jamf PID, exiting" DEBUG
    exit 2
  fi

  jamfCommand=$(ps -o command= ${jamfPid})
  printlog "jamfCommand is ${jamfCommand}" DEBUG

  blankWait=0
  while [[ "${jamfCommand}" == *"randomDelaySeconds"* ]]; do
    printlog "jamfCommand contains randomDelaySeconds, waiting for actual policy to start" DEBUG
    sleep 30
    jamfPid=$(getJamfPid)
    jamfCommand=$(ps -o command= ${jamfPid})
  done
  if [[ -z "${jamfPid}" ]]; then cleanupAndExit 0 "Failed to get jamf PID after waiting for random delay, exiting" INFO;fi
  jamfCommand=$(ps -o command= ${jamfPid})
  printlog "jamfCommand is now ${jamfCommand}" DEBUG

  # Begin Cleanup Loop
  while true; do
    etime=$(ps -ao etime= ${jamfPid})
    printlog "Process etime is $etime" DEBUG
    if [[ $etime == *"-"* ]]; then
      policyDays=$(ps -ao etime= ${jamfPid} | cut -d "-" -f1)
      printlog "Jamf Policy running for $policyDays days." DEBUG
    else
      printlog "Jamf Policy isn't older than a day." DEBUG
    fi
    if [[ $policyDays -ge 14 ]]; then
      longRunDebug=$(ps -ao 'etime= ppid= command= ' ${jamfPid})
      longRunDebug+=$(tail -n 20 /var/log/jamf.log)
      printlog "Jamf Policy running for more than 14 days, killing and refreshing LaunchDaemon. The system has been locked for $(beenLockedSince) seconds. Logs: ${longRunDebug}" WARN
      killall jamf
      restartJamfLaunchDaemon
    fi

    IFS=$'\n'
    jamfChildren=( $(pgrep -P $jamfPid) )
    printlog "jamfChildren for $jamfPid is '${jamfChildren[@]}' (count ${#jamfChildren[@]})" DEBUG
    if ! ps -p $jamfPid > /dev/null 2>&1 ; then
      cleanupAndExit 0 "Jamf process gone, exiting." INFO
    fi

    if [[ -n $jamfChildren ]]; then
      printlog "Found ${#jamfChildren[@]} jamf child processes" DEBUG
      printlog "jamfChildren is '${jamfChildren[@]}' (count ${#jamfChildren[@]})" DEBUG
      for child in "${jamfChildren[@]}"; do
        [[ -z "${child}" ]] && continue;
        printlog "Child pid is '${child}'" DEBUG
        local childCommand="$(ps -o command= ${child})"
        local childFile="$(echo ${${childCommand%%>& *}/*\/Library/\/Library} | cut -d "'" -f1)"
        childFile=${childFile##/bin/zsh }
        local childType=$(getJamfSubcommandType "${childCommand}")
        printlog "Policy Kill threshold is ${POLICY_KILL_THRESHOLD}" DEBUG
        local KILL_THRESHOLD=$(getJamfSubcommandThreshold "${childFile}" ${childType})
        printlog "Kill threshold is ${POLICY_KILL_THRESHOLD}" DEBUG
        if [[ "${childType}" == "extension-attribute" || "${childType}" == "policy" ]]; then
          if [[ ${+runningChildren[$child]} == 1 ]]; then
            runningChildren[$child]=$(( ${runningChildren[$child]} + 1))
            printlog "Child ${childType} at $child has been running for ${runningChildren[$child]} minutes ($KILL_THRESHOLD minutes allowed)" DEBUG
            if (( ${runningChildren[$child]} >= $KILL_THRESHOLD )); then
              printlog "childCommand is '${childCommand}'" INFO
              printlog "childFile is '${childFile}'" INFO
              childContents=$(head -20 "${childFile}" | awk '{printf "%s\\n", $0}')
              IFS=$' \t\n' children=($(list_descendants "$child")); IFS=$'\n'
              printlog "Children of $child are ${children[@]}" DEBUG
              childrenNames=$(ps -x -p $children[@] | awk '{printf "%s\\n", $0}')
              if [[ -z $childrenNames ]]; then
                printlog "Unable to get children Names, trying to be more Verbose." WARN
                childrenNames=$(ps -x -o "pid=ProcessID ppid=ParentID etime=ElapsedTime command=Command" -p $children[@])
              fi
              if [[ -z $childrenNames ]]; then
                printlog "Unable to get children Names, just listing everything." WARN
                childrenNames=$(ps -x -o "pid=ProcessID ppid=ParentID etime=ElapsedTime command=Command")
              fi

              echo $(date "+%Y-%m-%d %k:%M:%S") > "/Library/Application Support/JAMF/Last_Blocking_Policy_Date"
              echo "${childrenNames}" > "/Library/Application Support/JAMF/Last_Blocking_Policy_Child"
              printlog "Child ${childType} at $child has been running for longer than $KILL_THRESHOLD minutes. The system has been locked for $(beenLockedSince) seconds. Killing the ${childType}. First 20 lines of ${childFile} for debugging:\n${childContents}\nChild Processes: ${childrenNames}" ERROR
              printlog "Killing parent $child" DEBUG
              kill -9 $child
              printlog "Killing children $children" DEBUG
              for i in "${children[@]}"; do
                kill -9 "${i}"
                printlog "Killed child process ${i}" DEBUG
              done
              remainingChildren=($(pgrep -P $child 2>/dev/null))
              printlog "Remaining children of $child after kill attempt: ${remainingChildren[@]}" DEBUG
              if [[ ${#remainingChildren[@]} -eq 0 ]]; then
                printlog "All child processes of $child killed successfully" INFO
              else
                printlog "Failed to kill child processes of $child, remaining: ${remainingChildren[*]}" ERROR
              fi
              unset "runningChildren[${child}]"
            fi
          else
            printlog "Found ${childType} at pid $child ($(ps -o command= $child)), adding to watch-list" DEBUG
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
