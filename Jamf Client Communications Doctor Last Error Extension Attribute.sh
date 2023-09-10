#!/bin/zsh
###############################################################################
# Name:     Jamf Client Communications Doctor Last Error
# Creator:  Mann Consulting
# Summary:  Extension Attribute to report errors that Jamf Client communications doctor needed to fix. It will output failed Policy/Extension
#           Attribute children and their contents for debugging.
##
# More info: https://mann.com/jamf/doctor
#
# Note:     This script is part of Mann Consulting's Jamf Pro Workflows subscription and is made available free to the public with no guarantees
#           or support.  Mann Consulting is not responsible for data loss or other damages caused by use of this script.
#           Redistribution or commercial use without including this header is prohibited.
#           If you'd like updates or support sign up at https://mann.com/jamf or email support@mann.com for more details
###############################################################################

lastError=$(tail -n 3000 /var/log/JamfClientCommunicationsDoctor.log| awk 'BEGIN { error=0; str=""; } { if ($0 ~ / ERROR : /) { error=1; str=""; } if (error==1 && $0 ~ / INFO : /) { error=0 } else if (error==1) { str = str $0 "\n" } } END { printf "%s", str; }')

if [[ -n $lastError ]]; then
  echo "<result>$lastError</result>"
else
  echo "<result>No Errors</result>"
fi