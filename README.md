[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![ci](https://github.com/hawkmoth-studio/perforce-docker/workflows/ci/badge.svg)](https://github.com/hawkmoth-studio/perforce-docker/actions)

# IMPORTANT
This has been tested on Ubuntu 24.04 LTS only!

# KAIZEN CHANGES
This is based on the excellent hawkmoth-studio/perforce-docker repo, but with some additions.
1. Providing working docker container setups
2. The use of a .env file to store the setup and secrets
3. Adding backup scripts that will help journal + checkpoint, verify those backups, export those backups to S3, perform full rsync backups of all data, and report progress to slack and new-relic

## User Setup
If your running docker as a non-root user, it's likely that the process of checkpoint, journaling and rotating will cause p4 to shutdown due to assigning incorrect permissions to journal files. To solve this, we need to do some user remapping and namespacing. If you plan on running as root, you can probably ignore this section.

The idea is to:
1. Create a "perforce" user that will be used on the host as a proxy for the p4d user used on the container.
2. Create a user group to hold our ubuntu user as well as the new perforce one.
3. Configure the new perforce user to be used by Docker namespacing
4. Renumber the user to match what the P4 user will be - for the docker instance, it has an internal user that runs the p4d service that ends up being UID 101 - so we have to use the base ID (1000) + this internal ID (101) as our host’s proxy user


Ensure you are performing these steps on the host, not in the container.
```
sudo adduser --system --group docker-user-remap
sudo groupadd dockervolumes
sudo usermod -aG dockervolumes root
sudo usermod -aG dockervolumes <your_user_name>
sudo usermod -aG dockervolumes docker-user-remap
```
Note that adduser command above also adds a docker-user-remap group. We're not gonna use it, but it needs to exist for the docker namespace system to work fully.

Now add the user-id to the docker subuid and subgid
```
sudo nano /etc/subuid
```
and add
```
docker-user-remap:1000:1000
```
And repeat for thw subgid
```
sudo nano /etc/subgid
```
and add
```
docker-user-remap:1000:1000
```

Turn on docker namespace by editing the daemon.json
```
sudo nano /etc/docker/daemon.json
```
and adding the following
```
{
  "userns-remap": "docker-user-remap"
}
```
And now change the UID of the docker-user-remap user.
```
sudo usermod -u 1101 perforce
```

Reboot the server so the changes are applied.
```
sudo reboot
```

Now setup the data folder for the users. If you haven't already, create the data folder which will hold your volumes
```
sudo mkdir -p <my_data_dir>
```
And setup permissions
```
sudo chown -R docker-user-remap:dockervolumes /data
sudo chmod -R 2770 /data
sudo chmod g+s /data
```


## Additional Setup

It's best to perform some user remapping so that we have stability inside and outside of the container

Create your docker-compose.yaml file
```
cp sample.docker-compose.yaml docker-compose.yaml
```

Edit the docker-compose file
```
nano docker-compose.yaml
```

Setup the options as required, with particular focus on the volumes and ports. More information about the docker-compose can be found later in this document.

Make the .env file
```bash
cp sample.env .env
chmod 600 .env
```

Edit the new .env file to contain the details for the setup
```bash
nano .env
```

If you're using Swarm, make sure that the SWARM_USER matches the service user you created above 

Create the directory structure as specified in the docker-compose.yml file (e.g. /data/docker_volumes/perforce/data). Do this for both Perforce and Swarm (if deploying swarm)
```
sudo mkdir -p /data/docker_volumes/perforce/data
sudo mkdir -p /data/docker_volumes/perforce/typemap
sudo mkdir -p /data/docker_volumes/swarm/data
```



Now copy your typemap file into the typemap volume. Note that even if you are using one from this repo, it must be copied out of the p4-typemap folder and into here. If you don't want to setup a typemap, skip this step and also ensure your docker-compose.yaml has the typemap option set to false.
```
cp <my_typemap.txt> /data/docker_volumes/perforce/typemap/<my_typemap.txt>
```

If you've performed the user setup above, make sure these folders have the group 'dockervolumes' group and if not, assign it
```
sudo chown -R docker-user-remap:dockervolumes /data/docker_volumes
sudo chmod -R 2770 /data/docker_volumes/perforce
```

If you're not using the user setup above, then check the permissions look correct for your case.

## PREPARE FOR BACKUPS

Ensure that the scripts in the utils folder have the execution bit set.

Setup folders to match what's set in your .env script for the P4_BACKUP_DIR_DATA and P4_BACKUP_DIR_LOGS values
```
mkdir -p /data/perforce_backup/data
mkdir -p /data/perforce_backup/logs
```
And now setup permissions
```
chown -R 100000:p4group /data/perforce_backup
```

If you're using the rsync option to backup all data within perforce (warning - this could be A LOT of data), then you might need to supply a SSH key for rsync backup. Copy the private key to some directory as specified in the .env file and ensure the correct permissions are set. Make sure that this file is still kept securely.
```
chmod 600 <your_ssh_private_key_file>
chown <youruser> <your_ssh_private_key_file>
chgrp <youruser> <your_ssh_private_key_file>
```

If you're using S3 backup, install the offical S3 CLI (AWSCLI) and follow the setup instructions to connect to your bucket. Ensure that you have entered the correct values in the .env file

If you want the logs to report to Slack, setup a Slack bot for your account and setup the bot-token etc within the .env file

## FIREWALL SETUP
Open the relevent ports in your firewall (see docker-compose.yml for the correct ports)

## START THE DOCKER CONTAINER
Bring up the docker container
```
docker compose build --no-cache
docker compose up -d
```

Test it all works. Note that the details on first startup might be set as the below if you've not created any users as part of the setup. Also note that swarm might not work at this point if you've not setup users, that's OK, we'll fix that in a moment.
```
p4user
p4P@ssw0rd
```
If that's the case, login with that user then add whatever you need to match your .env and own usage requirements.

If it fails then make whatever changes are necessary, then rebuild the container
```
docker compose stop
docker rm <p4d-instance>
docker rm <p4d-swarm>
```
In some cases you might want to do a full rebuild
```
docker compose build --no-cache
```

## PERFORCE USERS
If everything is working, then move on to setting up your usernames (if needed). Add these via the command line or p4admin (GUI), whichever you prefer.

## SWARM USER SETUP
If you're using swarm, you should add a new swarm specific user to match the setup in the .env file. This user must:
1. NOT be prefixed with 'swarm-'
2. Be a 'standard' user type (which uses up one license slot - there's no way round this)
3. Have a secure password

You also need alter the permissions table, and add the swam user as an 'admin'.

It's also strongly recommended that you:
1. Create a new group (this can not start with 'swarm-'
2. Add the swarm user to the group
3. Set the ticket and auth lenths to be longer than standard. If you don't do this, you may need to get new tickets every 12 hours or so, and this also interupts proper operation of perforce.

## BACKUP SCRIPTS
Now setup the backup and verify scripts, and the .env you've created to see what services you need to install in order to support proper backups. Setup those services (such as awscli, ssh keys etc).


Test the backup script
```
cd utils/backup
./p4_backup.sh
```

Test the verify script
```
cd utils/verify
./p4_verify.sh
```

Now schedule backups to choose a time to perform the P4 backups
```bash
cd utils/backup
./schedule_backup
```

And now run schedule verify to choose a time to perform the P4 verify
```bash
cd utils/verify
./schedule_verify
```

Verify these have been entered correctly into cron
```
crontab -l
```

Perform any additional setup needed, such as installing aws cli, setting up ssh keys etc

NOTE: IT'S STRONGLY RECOMMENDED THAT YOU PERFORM A TEST RESTORATION TO ENSURE YOUR CHECKPOINTS AND JOURNALS ARE CREATED CORRECTLY.

## SECURELY BACK UP YOUR DOCKER-COMPOSE AND .ENV FILE
At this point you might want to backup your .env and docker-compose.yaml file, in case you ever need to setup on a new server. Ensure that any backups you take are kept securely, as they contain passwords and other information that could be exploited.

# Useful Info
If you need to make changes to the users, type map, versions or anything else then you should stop the docker containers, then rebuild without caching
```
docker ps <---- see running instances
docker compose stop <swarm-instance-name>
docker compose stop <p4d-instance-name>
docker compose build --no-cache
docker exec -it <instance-name> bin/bash <---This will let you use the cli within the docker container
docker exec -e P4CHARSET=utf8 -it <instance-name> bin/bash <--- as above, but forcing unicode
```

# perforce-docker
Docker images for Perforce source control.

## helix-p4d
This image contains a [Helix Core Server](https://www.perforce.com/products/helix-core).

### Quickstart
```bash
docker run -v /srv/helix-p4d/data:/data -p 1666:1666 --name=helix-p4d hawkmothstudio/helix-p4d
```

### Volumes
| Volume Name   | Description                                               |
| ------------- | --------------------------------------------------------- |
| /data         | Server data directory                                     |
| /p4-depots    | List of depot specifications to load on start             |
| /p4-groups    | List of group specifications to load on start             |
| /p4-passwd    | Users password to load on start                           |
| /p4-protect   | List of protections to load on start                      |
| /p4-typemaps  | List of protections to load on start                      |
| /p4-users     | List of user specifications to load on start              |

### Container environment variables
| Variable Name                      | Default value                          | Description                                                     |
| ---------------------------------- | -------------------------------------- | --------------------------------------------------------------- |
| P4NAME                             | master                                 | Service name, leave default value (recommended).                |
| P4ROOT                             | /data/master                           | p4d data directory, leave default value (recommended).          |
| P4SSLDIR                           | /data/master/root/ssl                  | Directory with ssl certificate and private key.                 |
| P4PORT                             | ssl:1666                               | Server port. By default, connection is secured by TLS.          |
| P4USER                             | p4admin                                | Login of the admin user to be created.                          |
| P4PASSWD                           | P@ssw0rd                               | Password of the admin user to be created.                       |
| P4CHARSET                          | `auto` if unicode is enabled.          | Charset the local client will to perform administrative tasks.  |
| P4D\_CASE\_SENSITIVE               | false                                  | Set to `true` to enable case-sensitive mode.                    |
| P4D\_USE\_UNICODE                  | true                                   | Set to `false` to disable unicode mode.                         |
| P4D\_FILETYPE\_BYPASSLOCK          | 1                                      | Enable / disable bypasslock (needed by Swarm).                  |
| P4D\_SECURITY                      | 2                                      | Server security level.                                          |
| P4D\_LOAD\_TYPEMAPS                | false                                  | If true, loads typemap specifications on startup.               |
| P4D\_LOAD\_USERS                   | false                                  | If true, loads user specifications on startup.                  |
| P4D\_LOAD\_USER\_PASSWORDS         | false                                  | If true, loads user passwords on startup.                       |
| P4D\_LOAD\_GROUPS                  | false                                  | If true, loads group specifications on startup.                 |
| P4D\_LOAD\_DEPOTS                  | false                                  | If true, loads depot specifications on startup.                 |
| P4D\_LOAD\_PROTECTIONS             | false                                  | If true, loads protection lists on startup.                     |
| P4D\_SSL\_CERTIFICATE\_FILE        |                                        | If set, file is copied and used as a TLS certificate.           |
| P4D\_SSL\_CERTIFICATE\_KEY\_FILE   |                                        | If set, file is copied and used as a TLS private key.           |
| P4D\_DATABASE\_UPGRADE             | false                                  | Set to `true` to attempt database upgrade on start.             |
| SWARM\_URL                         |                                        | If set, used to update P4.Swarm.URL property.                   |
| INSTALL\_SWARM\_TRIGGER            | false                                  | Set to `true` to automatically install / update swarm triggers. |
| SWARM\_TRIGGER\_HOST               | http://swarm                           | URL to be used by p4d to access Swarm.                          |
| SWARM\_TRIGGER\_TOKEN              |                                        | Swarm token. Required if swarm trigger installation is enabled. |

### Initial configuration
When started for the first time, a new p4d server is initialized with superuser identified by `$P4USER` and `$P4PASSWD`.
Changing these variables after the server has been initialized does not change server's superuser.

### Unicode support
When initializing, p4d can create database files with (by default) or without unicode support.
Please pay attention to this parameter when initializing p4d database, as unicode support cannot be turned off once it has been enabled.
It is enabled by default as using non-unicode servers today is rather rare and can lead to unexpected issues with file sync.

If `P4D_USE_UNICODE` is enabled after p4d database has been initialized,
`helix-p4d` will attempt to convert database files to unicode upon startup.

For more information on unicode support in Perforce, please refer to [official documentation](https://community.perforce.com/s/article/3106).

### Automatic data loading
`helix-p4d` supports loading certain data on startup.
This provides an easy way to automate production-ready container deployment.

#### Typemaps
If `P4D_LOAD_TYPEMAPS` is set to `true`, all `.txt`-files from `/p4-typemap`
are loaded as typemap specification files when starting container (in alphabetic order).

See the following example specification files:
* [default perforce typemap](helix-p4d/p4-typemap/default.sample)
* [typemap for a depot containing an Unreal Engine project](helix-p4d/p4-typemap/ue4.sample)

#### Users
If `P4D_LOAD_USERS` is set to `true`, all `.txt`-files from `/p4-users`
are loaded as user specification files when starting container (in alphabetic order).

Example specification file:
```text
User:       johndoe
Email:      john.doe@example.localdomain
FullName:   John Doe
```

#### User passwords
`p4d` disallows setting user password using specification file when security level is set to `2` or higher.
If `P4D_LOAD_USER_PASSWORDS` is set to `true`, container uses all `.txt`-files
from `/p4-passwd` to set/update user passwords on startup.
All files should be named `<username>.txt` and contain only corresponding user password (without newlines).

#### Groups
If `P4D_LOAD_GROUPS` is set to `true`, all `.txt`-files from `/p4-groups`
are loaded as group specification files when starting container (in alphabetic order).

Example specification file:
```text
Group:      admins
Owners:     p4admin
Users:
            p4admin
            johndoe
```

#### Depots
If `P4D_LOAD_DEPOTS` is set to `true`, default depot `depot` is not created,
and all `.txt`-files from `/p4-depots` are loaded as depot specification files
when starting container.

Please be advised, certain operations (e.g. updating depot type) is not supported this way.
In such case, perforce administrator should re-create perforce depot manually. 

Example specification file:
```text
Depot:          depot
Owner:          p4admin
Description:
                Default depot.
Type:           local
Address:        local
Suffix:         .p4s
StreamDepth:    //depot/1
Map:            depot/...
```

#### Depots
If `P4D_LOAD_PROTECTIONS` is set to `true`, all `.txt`-files from `/p4-protect` (in alphabetic order)
are merged together and loaded as protection specification when starting container.

Example specification file (see documentation for `p4 protect` for more details):
```text
    write user * * //...
    list user * * -//spec/...
    super user p4admin * //...
```

### TLS support
If `$P4PORT` value starts with `ssl:`, p4d is configured with TLS support.
It is strongly recommended to provide proper custom key and certificate using `P4D_SSL_CERTIFICATE_FILE` and `P4D_SSL_CERTIFICATE_KEY_FILE` environment variables are set - these file are copied into `$P4SSLDIR` as `certificate.txt` and `privatekey.txt`.
Otherwise, new key and certificate are automatically generated (only during initialization).

Attention: when server detects that key and/or certificate has changed, a new server fingerprint is generated.
All the clients (including local container client) must be updated to trust this new fingerprint.

### Swarm trigger support
If `INSTALL_SWARM_TRIGGER` is set to `true`, swarm trigger script and configuration is installed / updated on every container startup.
The following tasks are performed as part of trigger installation:
1. Script creates `.swarm` depot if it does not exist.
1. Script creates a temporary workspace and syncs it to temp directory. This workspace will be deleted later.
1. Script installs / updates `//.swarm/triggers/swarm-trigger.pl` from the official package.
1. Using `SWARM_TRIGGER_HOST` and `SWARM_TRIGGER_TOKEN`, the script installs / updates `//.swarm/triggers/swarm-trigger.conf`.
1. Script submits changes (if any) to the p4d server.
1. Script updated `p4 triggers` (see [official documentation](https://www.perforce.com/manuals/v18.1/cmdref/Content/CmdRef/p4_triggers.html)).

Beware, setting `INSTALL_SWARM_TRIGGER` to value other than `true` does not remove currently installed triggers!


## helix-swarm
This image contains a [Helix Swarm](https://www.perforce.com/products/helix-swarm) core review tool along with a Redis cache server.
Currently using external Redis server is not supported.

### Quickstart
```bash
docker run -it --rm -e P4PORT=ssl:p4d:1666 -p 80:80 --name helix-swarm hawkmothstudio/helix-swarm
```

### Volumes
| Volume Name              | Description           |
| ------------------------ | --------------------- |
| /opr/perforce/swarm/data | Server data directory |

### Container environment variables
| Variable Name                      | Default value                          | Description                                                     |
| ---------------------------------- | -------------------------------------- | --------------------------------------------------------------- |
| P4PORT                             | ssl:p4d:1666                           | p4d server connection string.                                   |
| P4USER                             | p4admin                                | User to be used when running p4 commands from console.          |
| P4PASSWD                           | P@ssw0rd                               | `$P4USER`'s password.                                           |
| P4CHARSET                          | `auto` if unicode is enabled.          | Charset the local client will to connect to p4d.                |
| P4D\_USE\_UNICODE                  | false                                  | Set to `true` if server uses unicode mode.                      |
| SWARM\_INIT\_FORCE                 | false                                  | Set to `true` to skip checking supplied P4PORT and credentials. |
| SWARM\_USER                        | p4admin                                | User to be used by Swarm to connect to p4d.                     |
| SWARM\_PASSWD                      | P@ssw0rd                               | `$SWARM_USER`'s password.                                       |
| SWARM\_USER\_CREATE                | false                                  | Set to `true` to create `$SWARM_USER` on the p4d server.        |
| SWARM\_GROUP\_CREATE               | false                                  | Set to `true` to create long-lived ticket group for swarm user. |
| SWARM\_HOST                        | localhost                              | Swarm machine hostname.                                         |
| SWARM\_PORT                        | 80                                     | Port Swarm is running on (HTTP).                                |
| SWARM\_SSL\_ENABLE                 | false                                  | Set to `true` to enable TLS support.                            |
| SWARM\_SSL\_CERTIFICATE\_FILE      | /etc/ssl/certs/ssl-cert-snakeoil.pem   | Path to certificate file.                                       |
| SWARM\_SSL\_CERTIFICATE\_KEY\_FILE | /etc/ssl/private/ssl-cert-snakeoil.key | Path to private key file.                                       |
| SWARM\_TRIGGER\_TOKEN              |                                        | Swarm trigger token to be installed, if not empty.              |
| SWARM\_P4D\_NOWAIT                 |                                        | Set to `true` to disable waiting for p4d to start.              |

### Initial configuration
When started, container checks if `/opt/perforce/swarm/data/config.php` is present.
If not, Swarm is initialized using provided environment variables.

After the container has been initialized, all modifications to the Swarm configuration should be done by editing the `config.php` (see [official documentation](https://www.perforce.com/manuals/swarm/Content/Swarm/admin.configuration.html)).

### TLS support
ATTENTION: it is highly recommended running Swarm behind a reverse proxy (e.g. httpd or nginx).
Running Swarm with TLS enabled can interfere with Swarm's P4 client and lead to certain bugs,
such as [NetSslTransport::SslClientInit SSL_load_error_strings: error:0909006C:PEM routines:get_name:no start lin](https://github.com/hawkmoth-studio/perforce-docker/issues/25). 

Set `SWARM_SSL_ENABLE` to `true` and provide correct certificate and key files to enable TLS support.
TLS support can be enabled/disabled/updated through the environment variables at any time (container restart is required).

### Swarm trigger support
If `SWARM_TRIGGER_TOKEN` is set, it is automatically added to a list of valid trigger tokens upon container startup.


## Examples
### Running with docker-compose
The following example `docker-compose.yml` starts both p4d and swarm:
```yaml
version: '2.1'
services:
  p4d:
    image: hawkmothstudio/helix-p4d
    ports:
      - '1666:1666'
    environment:
      P4USER: 'p4admin'
      P4PASSWD: 'MySup3rPwd'
      P4D_SSL_CERTIFICATE_FILE: '/etc/letsencrypt/live/example.com/fullchain.pem'
      P4D_SSL_CERTIFICATE_KEY_FILE: '/etc/letsencrypt/live/example.com/privkey.pem'
      SWARM_HOST: 'http://perforce.example.com'
      SWARM_URL: 'https://perforce.example.com'
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
      - /etc/letsencrypt:/etc/letsecnrypt:ro
      - /srv/helix/p4d/data:/data
  swarm:
    image: hawkmothstudio/helix-swarm
    ports:
      - '80:80'
      - '443:443'
    environment:
      P4PORT: 'ssl:p4d:1666'
      P4USER: 'p4admin'
      P4PASSWD: 'MySup3rPwd'
      SWARM_USER: 'swarm'
      SWARM_PASSWD: 'MySwa3mPwd'
      SWARM_USER_CREATE: 'true'
      SWARM_GROUP_CREATE: 'true'
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
      - /etc/letsencrypt:/etc/letsecnrypt:ro
      - /srv/helix/swarm/data:/opt/perforce/swarm/data
    depends_on:
      - p4d
```

### Loading typemap into p4d
Warning: helix-p4d image comes with pre-configured typemaps. Please consider using them first before using a custom typemap.

In this example we will load a [UE4 Perforce Typemap](https://docs.unrealengine.com/en-US/Engine/Basics/SourceControl/Perforce/index.html).

There is a [known issue](https://github.com/docker/compose/issues/3352) with `docker-compose` and piping, so we need to use the `docker` command:
```bash
 docker exec -i helix_p4d_1 p4 typemap -i <<EOF
# Perforce File Type Mapping Specifications.
#
#  TypeMap:             a list of filetype mappings; one per line.
#                       Each line has two elements:
#
#                       Filetype: The filetype to use on 'p4 add'.
#
#                       Path:     File pattern which will use this filetype.
#
# See 'p4 help typemap' for more information.

TypeMap:
                binary+w //depot/....exe
                binary+w //depot/....dll
                binary+w //depot/....lib
                binary+w //depot/....app
                binary+w //depot/....dylib
                binary+w //depot/....stub
                binary+w //depot/....ipa
                binary //depot/....bmp
                text //depot/....ini
                text //depot/....config
                text //depot/....cpp
                text //depot/....h
                text //depot/....c
                text //depot/....cs
                text //depot/....m
                text //depot/....mm
                text //depot/....py
                binary+l //depot/....uasset
                binary+l //depot/....umap
                binary+l //depot/....upk
                binary+l //depot/....udk
                binary+l //depot/....ubulk
EOF
```

