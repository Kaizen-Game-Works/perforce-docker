[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![ci](https://github.com/hawkmoth-studio/perforce-docker/workflows/ci/badge.svg)](https://github.com/hawkmoth-studio/perforce-docker/actions)

# IMPORTANT
This has been tested on Ubuntu 24.04 LTS only!

# KAIZEN CHANGES
This is based on the excellent hawkmoth-studio/perforce-docker repo, but with some additions.
1. Providing working docker container setups
2. The use of a .env file to store the setup and secrets
3. Support running docker as a non-root user on the host
4. Provide a build script which will allow you to update the images to get new versions of p4d / swarm
5. Adding backup scripts that will help journal + checkpoint, verify those backups, export those backups to S3, perform full rsync backups of all data, and report progress to slack and new-relic

NOTE: Swarm is now called Code Review, but we're gonna keep calling it Swarm.

## PREREQUISITES
This setup assumes:
1. You're going to run as a non-root user, and that you've already setup a non-root user on your server, and you can run docker as a non-root user.
2. You've installed docker and proven it works.
3. You don't have any linux user or group uid on 101 or 103 (see warning below)

## WARNINGS
The original hawkmoth depots put the interal docker "perforce" user and group on 101 and 102 respectively. To ensure compatability, we are continuing to use this same setup. You are welcome to change the UIDs if you need to (within helix-p4d/Dockerfile), however note that you will also need modify existing permissions if you have any existing data.

If you get a UID mismatch between the host and the container, you may lock up perforce when journaling - see the User Setup section for details. Ensure you test checkpointing and journaling fully before using this in production.

This setup relies on using docker namespaces (userns-remap). This can cause problems for some docker containers or build scripts. It's recommended you check your existing docker containers to see if using namespaces will cause problems, and if you're able to work around them. Sometimes that can be done by forcing the use of host in the docker-container, or build scripts.

We are not providing pre-built images for these builds. The build.sh script will build the images locally for you. This is to ensure you've got flexibility to do what you want without waiting for us to maintain the image.

# SETUP
Clone this repo to some location on your server
```
mkdir -p /srv/docker-containers
git clone https://github.com/Kaizen-Game-Works/perforce-docker
```

You should also make a new group on your server called dockervolumes
```
sudo groupadd dockervolumes
```

Now add users to the group
```
sudo usermod -aG dockervolumes root
sudo usermod -aG dockervolumes <your_non_root_linux_user>
```
Repeat for any other users you might want to add to have group access to your dockervolumes

Now create a folder where you would like your docker volumes to live. In this example we use data/docker_volumes
```
mkdir -p /data/docker_volumes
sudo chgrp -R dockervolumes /data/docker_volumes
sudo chmod -R 775 /data/docker_volumes
sudo chmod g+s /data/docker_volumes
```

## USER SETUP
When running as a non-root docker user, t's likely that the process of checkpoint, journaling and rotating will cause p4 to shutdown due to assigning incorrect permissions to journal files. To solve this, we need to do some user remapping and namespacing.

The idea is to:
1. Create a "docker-user-remap" user that will be used on the host as a proxy for the p4d user used on the container.
2. Add the user to the dockervolumes group we created before to hold our non-root user as well as the new docker-user-remap user we'll create below.
3. Configure the new docker-user-remap user to be used by Docker namespacing
4. Renumber the user to match what the P4 user will be - for the docker instance, it has an internal user that runs the p4d service that ends up being UID 101 - so we have to use the base ID (1000) + this internal ID (101) as our host’s proxy user


Ensure you are performing these steps on the host, not in the container.
```
sudo adduser --system --group docker-user-remap
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
And now change the UID of the docker-user-remap user, and the dockervolumes groups to match what's used within the container
```
sudo usermod -u 1101 docker-user-remap
sudo groupmod -g 1102 dockervolumes
```

Reboot the server so the changes are applied.
```
sudo reboot
```

If you can't reboot the server for whatever reason, instead you should logout and log back in again, and also restart the docker service. If you don't, user permissions won't work and the docker namespacing won't be correct.

Finally, we need to make sure that we setup the permissions for the perforce docker volumes on the host

Now setup the data folder for the users. If you haven't already, create the data folder which will hold your volumes. Customise the directory as needed
```
sudo mkdir -p /data/docker_volumes/perforce/data
sudo mkdir -p /data/docker_volumes/perforce/typemap
sudo mkdir -p /data/docker_volumes/swarm/data
sudo chown -R docker-user-remap:dockervolumes /data/docker_volumes/perforce/
sudo chown -R docker-user-remap:dockervolumes /data/docker_volumes/swarm/
sudo chmod -R 2770 /data/docker_volumes/perforce/
sudo chmod -R 2770 /data/docker_volumes/swarm/
sudo chmod g+s /data/docker_volumes/perforce/
sudo chmod g+s /data/docker_volumes/swarm/
```


## SETUP DOCKER-COMPOSE AND ENVIRONMENT

Create your docker-compose.yaml file
```
cp sample.docker-compose.yaml docker-compose.yaml
```

Edit the docker-compose file
```
nano docker-compose.yaml
```

Setup the options as required, with particular focus on the volumes and ports. More information about the docker-compose can be found later in this document.

Make the .env file. This will hold variables which will help setup docker, as well as the included backup scripts.
```bash
cp sample.env .env
chmod 600 .env
```

Edit the new .env file to contain the details for the setup
```bash
nano .env
```

Note that if you don't have any existing users, just use whatever you want for both the perforce and the swarm usernames / passwords (but make sure they're secure). We'll deal with adding swarm users later.

Now copy your typemap file into the typemap volume. Note that even if you are using one from this repo, it must be copied out of the p4-typemap folder and into here. If you don't want to setup a typemap, skip this step and also ensure your docker-compose.yaml has the typemap option set to false.
```
cp <my_typemap.txt> /data/docker_volumes/perforce/typemap/<my_typemap.txt>
```

Make sure the typemap will be readable by the container
```
sudo chown -R docker-user-remap:dockervolumes /data/docker_volumes/perforce/typemap/<my_typemap.txt>
```

# FIREWALL SETUP
Open the relevent ports in your firewall. Make sure you open the right ports as you may have chosen to use non-standard ones.

# START THE DOCKER CONTAINER
The first thing we need to do is build the images. You need to build because we don't provide the images so that you are able to maintain your own setups.
```
./build.sh
```
The building may take a while, so be patient. If it fails, you might need to run it without the namespace mapping. In which case:

```
sudo nano /etc/docker/daemon.json
```
Clear the file, then restart the docker service, and build again
```
sudo systemctl restart docker
./build.sh
```

Once that's built, you then need to save the image so we can use it against docker running with namespaces

```
docker save kaizengameworks/helix-p4d:latest kaizengameworks/helix-swarm:latest | gzip > /somedir/helix-images.tar.gz
```
Now rebuild the daemon.json (see proper contents above), then restart the docker container again.

Once the docker service is restarted, you need to load the images

```
gunzip -c helix-images.tar.gz | docker load
```

And verify the images have been loaded
```
docker image ls
```

Once it's done, bring up the docker container
```
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
./build.sh
```

# PERFORCE USERS
If everything is working, then move on to setting up your usernames (if needed). Add these via the command line or p4admin (GUI), whichever you prefer.

# SWARM SETUP
If you're using swarm, you should add a new swarm specific user to match the setup in the .env file. This user must:
1. NOT be prefixed with 'swarm-'
2. Be a 'standard' user type (which uses up one license slot - there's no way round this)
3. Have a secure password

You also need alter the permissions table, and add the swam user as an 'admin'.

It's also strongly recommended that you:
1. Create a new group (this can not start with 'swarm-'
2. Add the swarm user to the group
3. Set the ticket and auth lenths to be longer than standard. If you don't do this, you may need to get new tickets every 12 hours or so, and this also interupts proper operation of perforce.

Swarm may not configure itself properly on first startup. If you don't have a .swarm depot, then it's not setup. To fix this follow these instructions to access the swarm container and setup.
```
docker exec -it perforce-swarm-1 bin/bash
/opt/perforce/swarm/sbin/configure-swarm.sh
exit
```

Once that's complete, now access the perforce container and install the triggers
```
docker exec -it perforce-p4d-1 bin/bash
FINISH.....
```

# BACKUPS

Setup folders to match what's set in your .env script for the P4_BACKUP_DIR_DATA and P4_BACKUP_DIR_LOGS values
```
mkdir -p /data/perforce_backup/data
mkdir -p /data/perforce_backup/logs
```

The backup scripts support multiple options for backup including:
1. Backing up journals, checkpoints, serverid and licenses files to S3
2. Backing up journals, checkpoints, serverid and licenses files to another remote location (via rsync and ssh)
3. Backing up the whole depot to a remote location (via rsync and ssh)

### BACKUP TO S3
Note that this is only backing up journals, checkpoints, serverid and licenses files, not the full depot! Don't rely on this alone and ensure that you have some way to restore all the depot in case of disaster

You'll need to have an S3 bucket setup, and a user which can write to that bucket via AWSCLI. We're not going to cover all that here, but there are lots of guides available to help. 

Once you have setup the bucket, download and install AWSCLI to your server and run configure to perform the required setup
```
aws configure
```

Assuming you have provided valid information and enabled S3 backups in the .env file, this should now work.

### BACKUP TO REMOTE LOCATION
The backup scripts let you back up both the journals, checkpoints, serverid and licenses files, and the whole depot. You can choose to do non of these, either one or both. If you're using S3 as described above you don't really need to also bakckup the checkpoints / journals etc here, but it doesn't hurt to be careful.

If you're using the rsync option to backup all data within perforce then this could be A LOT of data. Be careful about any egress limits or costs you might have!

The script assums rsync requires a ssh key. Copy the private key to some directory as specified in the .env file and docker-compose volumes, and ensure the correct permissions are set. Make sure that this file is still kept securely.
```
sudo mkdir -p /etc/my-secrets-folder/perforce
sudo chmod 700 /etc/my-secrets-folder/perforce
sudo cp <your_file> /etc/my-secrets-folder/perforce/<your_file>
sudo chmod 600 /etc/my-secrets-folder/perforce/<your_file>
sudo chown docker-user-remap:dockervolumes /etc/my-secrets-folder/perforce/<your_file>
```

Make sure that all other the variables are setup correctly in the .env for your needs.

### BACKUP REPORTS AND LOGS
The backup script will output logs to the location you've specified, but you can also choose to send them to Slack and New Relic. I like to send them to slack because I use it every day, and it's a reliable way to see any issues. If you want the logs to report to Slack, setup a Slack bot for your account, give it posting permission to your chosen channel and setup the bot-token etc within the .env file. Instructions for all this can be found in the slack documentation.

## BACKUP TEST AND SCHEDULE
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

Now schedule backups to choose a time to perform the P4 backups. Note that this script is setup configured to only offer nightly builds. Customise as needed, or just inspect the script and setup your own cron job if you don't want it once per night.
```bash
cd utils/backup
./schedule_backup
```

And now run schedule verify to choose a time to perform the P4 verify. Note that this script is setup configured to only offer weekly verifications. Customise as needed, or just inspect the script and setup your own cron job if you don't want it once per week.
```bash
cd utils/verify
./schedule_verify
```

Verify these have been entered correctly into cron
```
crontab -l
```

Perform any additional setup needed, such as installing aws cli, setting up ssh keys etc

#FINAL BACKUP WARNING
You MUST do your own tests to ensure your backup and restoration process works. It's very easy to accidentally miss files, or for the checkpoints to be performed incorrectly due to a dir mismatch, or for syncronisation to fail so it's essential you test and monitor it! Do not assume the provided scripts will just work!

# SECURELY BACK UP YOUR DOCKER-COMPOSE AND .ENV FILE
At this point you might want to backup your .env and docker-compose.yaml file, in case you ever need to setup on a new server. Ensure that any backups you take are kept securely, as they contain passwords and other information that could be exploited.

# USEFUL INFO
If you need to make changes to the users, type map, versions or anything else then you should stop the docker containers, then rebuild without caching
```
docker ps <---- see running instances
docker compose up -d <---- ommit the d flag if you want to see what's happening in startup
docker compose stop <id>
docker rm <id> <---- remove a container, it doesn't remove the data
docker compose build --no-cache <---- recommend using the ./build.sh script instead of this
docker exec -it <instance-name> bin/bash <---This will let you use the cli within the docker container
docker exec -e P4CHARSET=utf8 -it <instance-name> bin/bash <--- as above, but forcing unicode
docker image ls <---- See images you've build
docker image rm <id> <----- remove any image
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

