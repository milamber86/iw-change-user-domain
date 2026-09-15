#!/bin/bash
# Global variables
# Domain migration script
# Script migrates users within the domains. MySQL credentials in .my.cnf required.
# -----------------------
# Authors: Otto Beranek, Tomas Jurica
# Version: 20250409
# Version notes: added support for custom alias rename while migration
# 

## TO ASK:
## Do we want to change members in group after migration (substitute domain) ?
# 0 User - DONE
# 1 Mailing list - DONE
# 2 Execultable - DONE
# 3 Notification - DONE
# 4 Static route - DONE
# 5 Catalog - DONE
# 6 List server - DONE
# 7 Group - DONE
# 8 Resource - DONE

## Variables set by the user from CLI
sourcedom="" # source domain name
targetdom="" # destination domain name
userlist="" # list of email addresses ( delimited by newline ) of the accounts we want to move from $sourcedom to $targetdom domains

## Fixed variables - if needed, can be modified here.
default_userlist="domain_users.txt"
iw_install_folder="/opt/icewarp"
iw_owner="icewarp"
iw_group="icewarp"
tool_sh="${iw_install_folder}/tool.sh"
icewarpd="${iw_install_folder}/icewarpd.sh"

## Dynamicaly set variables by the script
accdbname="";grwdbname="";dcdbname="";easdbname="";wcdbname="";mailpath="";sourcepath="";targetpath="";wholedomain=0;configpath="";

slog()
{
  echo "${1}" 
  echo "$(date +"%b %d %H:%M:%S.%3N")     ${1}" >> "domain_rename.log"
}

# This function checks is source domain and target domain variables are set, creates target domain and checks if both paths exists.
# Database names are set from tool.sh and the connection is also checked.
# If not given any userlist, all accounts from the domain are taken.
# If userlist is given, function checks if all the accounts are from the source domain and in correct form.
Preflight()
{
  slog "Preflight checks started"

  if [[ ${sourcedom} == "" ]] || [[ ${targetdom} == "" ]]
  then
    slog "Source domain and target domain are required! Terminating."
    PrintHelp
    exit 1
  fi

  accdbname="$(${tool_sh} get system C_System_Storage_Accounts_ODBCConnString | cut -d' ' -f2 | cut -d';' -f1)"
  grwdbname="$(${tool_sh} get system C_GW_ConnectionString | cut -d' ' -f2 | cut -d';' -f1)"
  dcdbname="$(${tool_sh} get system C_Accounts_Global_Accounts_DirectoryCacheConnectionString | cut -d' ' -f2 | cut -d';' -f1)"
  easdbname="$(${tool_sh} get system C_ActiveSync_DBConnection | cut -d' ' -f2 | cut -d';' -f3 | cut -d'=' -f2)"
  wcdbname="$(grep -P "<dbconn>.*?</dbconn>" ${iw_install_folder}/config/_webmail/server.xml | cut -d';' -f3 | cut -d'=' -f2 | sed 's|</dbconn>$||g')"
  mailpath="$(${tool_sh} get system C_System_Storage_Dir_MailPath | cut -d' ' -f2 | sed 's/\/$//g')"
  sourcepath="${mailpath}/${sourcedom}"
  targetpath="${mailpath}/${targetdom}"
  configpath="$(${tool_sh} get system c_configpath | cut -d' ' -f2 | sed 's/\/$//g')"
  archivepath="$(${tool_sh} get system C_System_Tools_AutoArchive_Path | cut -d' ' -f2 | sed 's/\/$//g')"

  # Database connections check

  if [[ ${accdbname} == "" ]] || [[ ${grwdbname} == "" ]] || [[ ${dcdbname} == "" ]] || [[ ${easdbname} == "" ]] || [[ ${wcdbname} == "" ]]
  then
    slog "Some of the database variables are empty. Terminating."
    exit 1
  fi

  for dbname in accdbname grwdbname dcdbname easdbname wcdbname
  do
    local tables="$(echo -e "use ${!dbname}; show tables;" | mysql)"
    if [[ $? -ne 0 ]]
    then
      slog "Cannot connect to ${!dbname} database. Terminating."
      exit 1
    fi
  done

  # Create target domain and maildir path
  ${tool_sh} create domain "${targetdom}"
  mkdir -p ${targetpath}
  chown "${iw_owner}":"${iw_group}" "${targetpath}"

  if [ ! -d "${sourcepath}" ] || [ ! -d "${targetpath}" ] || [ ! -d "${configpath}" ] 
  then
    slog "Sourcepath or targetpath or configpath or archivepath does not exist."
    slog "Source path: \"${sourcepath}\""
    slog "Target path: \"${targetpath}\""
    slog "Config path: \"${configpath}\""
    slog "Archive path: \"${archivepath}\""
    slog "Terminating."
    exit 1
  fi

  mkdir -p "${archivepath}/${targetdom}"
  chown "${iw_owner}":"${iw_group}" "${archivepath}/${targetdom}"
  # Check if limit path is given

  if [[ ${userlist} != "" ]] && [[ -f "${userlist}" ]]
  then
    local not_from_domain="$(cut -d',' -f1 ${userlist} | cut -d'@' -f2 | grep -v "${sourcedom}" | wc -l)"
    if [[ ${not_from_domain} -gt 0 ]]
    then
      slog "Email address from another domain found in ${userlist}."
      slog "Terminating"
      exit 1
    fi

    local number_of_users="$(cut -d',' -f1 ${userlist} | grep -P ".+?@.+" | wc -l)"
    
    if [[ ${number_of_users} -gt 0 ]]
    then
      slog "${number_of_users} valid users found to be migrated."
    else
      slog "No valid email addresses found in ${userlist}."
      slog "Terminating."
      exit 1
    fi
  else
    slog "No userlist found. Whole domain will be migrated."
    userlist="${default_userlist}"
    ${tool_sh} export account "*@${sourcedom}" | grep -v "##internalservicedomain.icewarp.com##," | cut -d',' -f1 > "${userlist}"

    if [[ $? -ne 0 ]]
    then
      slog "Not able to export accounts using tool.sh"
      exit 1
    else
      slog "Accounts for whole domain exported."
    fi
  fi

  while IFS='\n' read email
  do
    local source_email="$(echo "${email}" | cut -d',' -f1)"
    ${tool_sh} set account "${source_email}" U_AccountDisabled 2
    slog "${source_email} disabled."
  done < "${userlist}"

  ${icewarpd} --restart all

  slog "Preflight checks are done"

  Migrate


 
}

# This will be splitted into more separated functions
Migrate()
{
  slog "Migration started"
  local at_least_one=0

  while IFS='\n' read email_line
  do

    # If there is just one column, both variables equals and that means no ALIAS RENAME SHOULD BE DONE
    local source_email="$(echo "${email_line}" | cut -d',' -f1)"
    local target_email="$(echo "${email_line}" | cut -d',' -f2)"
    
    CUSTOM_TARGET_EMAIL=0
    # Only if gathered values differ, that means ALIAS RENAME should be done
    if [[ ${source_email} != ${target_email} ]]
    then
      CUSTOM_TARGET_EMAIL=1
    fi 

    local source_usernamedb="$(${tool_sh} export account ${source_email} u_alias | cut -d',' -f2)"
    local source_username="$(echo "${source_usernamedb}" | cut -d';' -f1)"

    local target_username="$(echo "${target_email}" | cut -d'@' -f1)"

    local rc1=0

    if [[ ${source_username} =~ "not found" ]]
    then
      slog "${source_username} not found. Skipping."
      rc1=1
    else

    # 5 variables are set from the snippet above - source_email, source_usernamedb, source_username, target_email, target_username
    # If no second field is provided, that means NO SPECIAL TARGET exists and TARGET has the same values are SOURCE

    local from="$(${tool_sh} export account "${source_email}" u_fullmailboxpath | cut -d',' -f2 | sed -r "s|${sourcepath}/(.*)/|${sourcepath}/\1|")"
    local to="$(${tool_sh} export account "${source_email}" u_fullmailboxpath | cut -d',' -f2 | sed -r "s|${sourcepath}/(.*)/|${targetpath}/\1|")"

    if [[ "${CUSTOM_TARGET_EMAIL}" -eq 1 ]]
    then
      local to="${targetpath}/${target_username}"
    fi

    local usertype="$(${tool_sh} export account "${source_email}" u_type | cut -d',' -f2)"

    local from_config="${configpath}/${sourcedom}/${source_username}.txt"
    local to_config="${configpath}/${targetdom}/${target_username}.txt"

      
      # If not something that has nothing in fullmailboxpath
      # if usertype is not 1 and is not 2
        if [ -d "${to}" ] 
        then
          slog "Not moving ${from}, target path ${to} already exists!"
          rc1=1
        elif [ ! -d "${from}" ] # In this case we assume that there are no data on the FS to migrate (mailing list, executable for example)
        then
          rc1=0
        else
          slog "$source_email is being migrated [maildata]."
          slog "Detected user type: ${usertype}"
          slog "Migrating FS data from ${from} to ${to}"
          mv -v "${from}" "${to}"
          rc1=$?
        fi

      # Check if something in config/ path is needed to remove
        if [ -f "${to_config}" ] 
        then
          slog "Not moving ${from_config}, target path ${to_config} already exists!"
          rc1=1
        elif [ ! -f "${from_config}" ] # In this case we assume that there are no data on the FS to migrate (mailing list, executable for example)
        then
          rc1=0
        else
          slog "$source_email is being migrated [configdata]."
          slog "Detected user type: ${usertype}"
          slog "Migrating on FS from ${from_config} to ${to_config}"
          mv -v "${from_config}" "${to_config}"
          rc1=$?
        fi

    fi

    # Continue with DB and other changes if account should be migrated
    if [ $rc1 -eq 0 ]
    then
      
      if [ ! -d "${archivepath}/${targetdom}/${target_username}" ] && [ -d "${archivepath}/${sourcedom}/${source_username}" ]
      then
        slog "Moving archive"
        mv -v "${archivepath}/${sourcedom}/${source_username}" "${archivepath}/${targetdom}/${target_username}"
        chown -R "${iw_owner}":"${iw_group}" "${archivepath}/${targetdom}/${target_username}"
      fi
      slog "Starting DB updates for ${source_email}"
      at_least_one=1
      chown -R "${iw_owner}":"${iw_group}" "${to}" 2> /dev/null
      chown "${iw_owner}":"${iw_group}" "${to_config}" 2> /dev/null

      # By default, newemail is set by substitution sourcedomain with targetdomain - this will be used for DB updates (GW, EAS, ...)
      local newemail="$(echo "${source_email}" | sed -r "s|(.*)@${sourcedom}|\1@${targetdom}|g" )"

      ## In case CUSTOM target email is provided from listfile, target_email is treaten as newemail.. that means it contains new alias as well
      if [[ "${CUSTOM_TARGET_EMAIL}" -eq 1 ]]
      then
        newemail="${target_email}"
      fi        

      # ACC DB updates
      local userid="$(echo -e "use ${accdbname};SELECT U_ID FROM Users WHERE U_Alias = \x27${source_usernamedb}\x27 AND U_Domain = \x27${sourcedom}\x27;" | mysql | grep -v U_ID)"
      
      echo -e "use ${accdbname};UPDATE Users SET U_Domain = \x27${targetdom}\x27 WHERE U_ID = \x27${userid}\x27;" | mysql
      echo -e "use ${accdbname};UPDATE Aliases SET A_Domain = \x27${targetdom}\x27 WHERE A_UserID = \x27${userid}\x27" | mysql
      
      # Change aliases only if CUSTOM target email is provided
      if [[ "${CUSTOM_TARGET_EMAIL}" -eq 1 ]] && [[ "${userid}" != "" ]]
      then
        echo -e "use ${accdbname};UPDATE Users SET U_Alias = \x27${target_username}\x27 WHERE U_ID = \x27${userid}\x27;" | mysql

        # First we need to delete all records from Aliases where A_UserID matches with the U_ID (update is not possible since there is a constraint...)
        echo -e "use ${accdbname};DELETE FROM Aliases WHERE A_UserID = \x27${userid}\x27 AND A_Domain = \x27${sourcedom}\x27;" | mysql
        echo -e "use ${accdbname};INSERT INTO Aliases (A_Alias, A_Domain, A_UserID) VALUES (\x27${target_username}\x27, \x27${targetdom}\x27, \x27${userid}\x27);" | mysql

        #echo -e "use ${accdbname};UPDATE Aliases SET A_Alias = \x27${target_username}\x27 WHERE A_UserID = \x27${userid}\x27;" | mysql      
      fi

      # Related for other types than user, but still for acc db
      local config_sourcedom="${sourcedom}\x5C\x5C${source_username}.txt"
      local config_targetdom="${targetdom}\x5C\x5C${target_username}.txt"

      echo -e "use ${accdbname};UPDATE Users SET U_Mailbox = \x27${config_targetdom}\x27 WHERE U_ID = \x27${userid}\x27 AND U_Mailbox = \x27${config_sourcedom}\x27;" | mysql
      echo -e "use ${accdbname};UPDATE Users SET U_Mailbox = \x27${targetdom}/${target_username}.txt\x3B\x27 WHERE U_ID = \x27${userid}\x27 AND U_Mailbox = \x27${sourcedom}/${source_username}.txt\x3B\x27;" | mysql
      echo -e "use ${accdbname};UPDATE Users SET U_Mailbox = \x27${targetdom}/${target_username}.txt\x27 WHERE U_ID = \x27${userid}\x27 AND U_Mailbox = \x27${sourcedom}/${source_username}.txt\x27;" | mysql
      echo -e "use ${accdbname};UPDATE Users SET U_ForwardOlderTo = \x27${targetdom}/${target_username}.txt\x27 WHERE U_ID = \x27${userid}\x27 AND U_ForwardOlderTo = \x27${sourcedom}/${source_username}.txt\x27;" | mysql
    
      # GW related - get IDs
      local gwownid=$(echo -e "use ${grwdbname};SELECT OWN_ID FROM EventOwner WHERE OWN_Email = \x27${source_email}\x27;" | mysql | grep -v OWN_ID | awk '{print $1}');
      local gwgrpid=$(echo -e "use ${grwdbname};SELECT GRP_ID FROM EventGroup WHERE GRPOWN_ID = (SELECT OWN_ID FROM EventOwner WHERE OWN_Email = \x27${source_email}\x27);" | mysql | grep -v GRP_ID | awk '{print $1}')
      #local newemail="$(echo "${email}" | sed -r "s|(.*)@${sourcedom}|\1@${targetdom}|g" )"
      
      if [[ ${gwownid} != "" ]]
      then
        echo -e "use ${grwdbname};UPDATE EventOwner SET OWN_Email = \x27${newemail}\x27 WHERE OWN_ID = \x27${gwownid}\x27" | mysql
      fi

      if [[ ${gwgrpid} != "" ]]
      then 
        echo -e "use ${grwdbname};UPDATE EventGroup SET GrpDailyEventsEmail = \x27${newemail}\x27 WHERE GRP_ID = \x27${gwgrpid}\x27" | mysql
        echo -e "use ${grwdbname};UPDATE EventGroup SET GrpReminderEmail = \x27${newemail}\x27 WHERE GRP_ID = \x27${gwgrpid}\x27" | mysql
      fi


      if [[ ${usertype} -ne 2 ]] # Executable stores there custom string so I am not sure if we really want to modify it
      then
        # Set new u_mailboxpath by substituting just domains in the string
        local newmpath=$(${tool_sh} export account "${newemail}" u_mailboxpath | awk -F ',' '{print $2}' | sed -r "s|${sourcedom}|${targetdom}|")

        # If u_mailboxpath is not empty (not mailing list etc...) and CUSTOM_TARGET_EMAIL is set, it must be also changed to the correct alias, not just domain..
        if [[ ${newmpath} != "" ]] && [[ "${CUSTOM_TARGET_EMAIL}" -eq 1 ]]
        then
          local newmpath=${targetdom}/${target_username}/
        fi

      fi

      # directory cache related - disabled for now since it is pretty slow on large mailboxes
      #local dcpaths="$(echo -e "use ${dcdbname}; SELECT search_path from directorycache where search_path like \x27${sourcedom}/${username}/%\x27;" | mysql | grep -v "search_path")"
      #while IFS= read -r dcpath
      #do
      #  local newdcpath="$(echo "${dcpath}" | sed -r "s|^${sourcedom}/|${targetdom}/|g")"
      #  if [[ "${dcpath}" != "" ]] && [[ "${newdcpath}" != "" ]]
      #  then
      #    echo -e "USE ${dcdbname}; UPDATE directorycache SET search_path = \x27${newdcpath}\x27 WHERE search_path = \x27${dcpath}\x27;" | mysql
      #  fi
      #done <<< "${dcpaths}"

      # EAS devices related
      echo -e "USE ${easdbname}; UPDATE devices SET user_id = \x27${newemail}\x27 WHERE user_id = \x27${source_email}\x27;" | mysql

      # Webmail cache related
      echo -e "USE ${wcdbname}; UPDATE folder SET account_id = \x27${newemail}\x27 WHERE account_id = \x27${source_email}\x27;" | mysql 
      local wcpaths="$(echo -e "USE ${wcdbname}; SELECT path FROM folder WHERE path like \x27${sourcepath}/${source_username}/%\x27;" | mysql | grep -v "path")"
      while IFS= read -r wcpath
      do
        local newwcpath="$(echo "${wcpath}" | sed -r "s|^${sourcepath}/${source_username}/(.*)|${targetpath}/${target_username}/\1|g")"
        #echo $newwcpath
        if [[ "${wcpath}" != "" ]] && [[ "${newwcpath}" != "" ]]
        then
          echo -e "USE ${wcdbname}; UPDATE folder SET path = \x27${newwcpath}\x27 WHERE path = \x27${wcpath}\x27;" | mysql
        fi
      done <<< "${wcpaths}"

      # GroupWare related - works ONLY for users, make sure it is the same for any other user type -  seems to be okay everytime
      echo -e "USE ${grwdbname}; UPDATE folderrights SET FrtEmail = \x27${newemail}\x27 WHERE FrtEmail = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE eventcontact SET CntEmail = \x27${newemail}\x27 WHERE CntEmail = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE contactlocation SET LctEmail1 = \x27${newemail}\x27 WHERE LctEmail1 = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE contactlocation SET LctEmail2 = \x27${newemail}\x27 WHERE LctEmail2 = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE contactlocation SET LctEmail3 = \x27${newemail}\x27 WHERE LctEmail3 = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE eventpin SET PinOwnEmail = \x27${newemail}\x27 WHERE PinOwnEmail = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE globaleventpin SET PinOwnEmail = \x27${newemail}\x27 WHERE PinOwnEmail = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE eventmyreaction SET ReaOwnEmail = \x27${newemail}\x27 WHERE ReaOwnEmail = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE eventmymention SET MenWhoOwnEmail = \x27${newemail}\x27 WHERE MenWhoOwnEmail = \x27${source_email}\x27;" | mysql
      echo -e "USE ${grwdbname}; UPDATE eventmymention SET MenLinkEmail = \x27${newemail}\x27 WHERE MenLinkEmail = \x27${source_email}\x27;" | mysql

      ${tool_sh} set account "${newemail}" u_mailboxpath "${newmpath}"
      ${tool_sh} set account "${newemail}" u_directorycache_refreshnow 1
      ${tool_sh} set account "${newemail}" U_Fulltext_ReindexAccount 1
      ${tool_sh} set account "${newemail}" U_AccountDisabled 0
      slog "${newemail} enabled."

      if [[ "${CUSTOM_TARGET_EMAIL}" -eq 1 ]]
      then
        sed -i -r "s|${source_username}@${sourcedom}|${target_username}@${targetdom}|g" "${to}/~webmail/settings.xml" 2>/dev/null
      else
        sed -i -r "s|${sourcedom}|${targetdom}|g" "${to}/~webmail/settings.xml" 2>/dev/null
      fi
    fi
  
  done < "${userlist}"
  slog "All users migrated."

  if [[ ${at_least_one} -eq 1 ]]
  then
    Postflight
  fi

}


# This function is responsible for some after-migration tasks, that should be done
# For example services restart, directory cache refresh and so
# We will see if it will be needed :)
Postflight()
{
  echo "Running postflight tasks"  
  ${icewarpd} --restart all
}


PrintHelp() {
    cat << EOF

Domain migration tool.
----------------------
This tool migrates users from one domain to another. Only selected users or whole domain can be migrated.
Usage: domain_rename.sh -s SOURCE_DOMAIN -d DESTINATION_DOMAIN [ -l USERFILE || -c USERFILE]

-s SOURCE DOMAIN          REQUIRED. Example: olddomain.cz
-d DESTINATION DOMAIN     REQUIRED. Example: newdomain.cz
-l LIMIT                  optional  Path to the limit file with users from SOURCE domain to migrate. It can have two line formats
                                      1. "email" - one email per line.
                                            That means account will be MIGRATED from SOURCE DOMAIN to DESTINATION DOMAIN without any alias change    
                                      2. "oldemail,newemail" - two mails per line comma delimited. 
                                            That means account will be MIGRATED and ALIAS RENAMED from SOURCE DOMAIN to DESTINATION DOMAIN
                                            Remember that only 1 source and 1 target domain is allowed per file (only one pair per file)
                                    Desired functionality is auto-detected based on a file format so both formats are acceptable.
                                    Example: /root/users_rename.txt              

Example run:

./domain_rename.sh -s olddomain.cz -d newdomain.cz
./domain_rename.sh -s olddomain.cz -d newdomain.cz -l /root/users.txt

EOF
}

## MAIN CODE
OPTSTRING=":s:d:l:h"
slog ""
while getopts ${OPTSTRING} opt; do
  case ${opt} in
    s)
      slog "Source domain: ${OPTARG}"
      sourcedom="${OPTARG}"
      ;;
    d)
      slog "Destination domain: ${OPTARG}"
      targetdom="${OPTARG}"
      ;;
    l)
      slog "Limit file: ${OPTARG}"
      userlist="${OPTARG}"
      ;;
    h)
      PrintHelp
      ;;
    :)
      slog "Option -${OPTARG} requires an argument."
      exit 1
      ;;
    ?)
      slog "INVALID OPTION: -${OPTARG}"
      slog "Terminating."
      exit 1
      ;;
  esac
done

Preflight



