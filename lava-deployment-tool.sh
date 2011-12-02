#!/bin/sh

set -e

# Global Configuration

# All LAVA instances are created relative to this path
LAVA_PREFIX=/srv/lava

# Prepare pip cache
export PIP_DOWNLOAD_CACHE=$LAVA_PREFIX/.downloads

# All LAVA uses this python version
LAVA_PYTHON=python2.6

# All of LAVA is being served by this uWSGI version
LAVA_UWSGI=0.9.9.2

# Current version of setup required by lava (global state)
export LAVA_SETUP_REQUIRED_VERSION=16

# Check if this installation is supported
export LAVA_SUPPORTED=0


os_check() {
    case `lsb_release -i -s` in
        Ubuntu)
            case `lsb_release -c -s` in
                lucid)
                    export LAVA_PYTHON=python2.6
                    export LAVA_SUPPORTED=1
                    # Required system packages
                    LAVA_PKG_LIST="python-virtualenv git-core build-essential $LAVA_PYTHON-dev libxml2-dev apache2 apache2-dev postgresql rabbitmq-server"
                    ;;
                oneiric)
                    export LAVA_PYTHON=python2.7
                    export LAVA_SUPPORTED=1
                    LAVA_PKG_LIST="python-virtualenv git build-essential $LAVA_PYTHON-dev libxml2-dev apache2 apache2-dev postgresql rabbitmq-server"
                    ;;
            esac
            ;;
    esac
}


install_user() {
    LAVA_INSTANCE=$1
    set -e
    set -x

    logger "Creating system user for LAVA instance $LAVA_INSTANCE"
    sudo useradd --system --comment "User for LAVA Instance" $LAVA_INSTANCE

    set +x
    set +e
}


install_fs() {
    LAVA_INSTANCE=$1
    set -e
    set -x

    logger "Creating filesystem structure for LAVA instance $LAVA_INSTANCE"
    # Create basic directory structure
    # Apache site:
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/apache2/sites-available
    # Dashboard reports
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/reports
    # Dashboard data views
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/views
    # Custom templates
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/templates
    # Static file cache
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/static
    # Repository of precious user-generated data (needs backup)
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/media
    # Celery state 
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-celery
    # Log files
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/log
    # Sockets and other runtime stuff
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/run
    # Source code (used when tracking trunk)
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/src
    # Temporary files
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/tmp

    # Allow apache (running as www-data) to read our public web files 
    sudo chgrp -R www-data $LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/
    sudo chmod -R g+rXs $LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/
    # Allow instance user to read all lava-server settings
    sudo chgrp -R $LAVA_INSTANCE $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server
    sudo chmod -R g+rXs $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/
    # Allow instance to write to media directory
    sudo chgrp -R $LAVA_INSTANCE $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/
    sudo chmod -R g+rwXs $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/
    # Prevent anyone else from reading from the media directory
    sudo chmod -R o-rX $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/
    # Allow instance to store lava-celery state 
    sudo chgrp -R $LAVA_INSTANCE $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-celery/
    sudo chmod -R g+rwXs $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-celery/
    # Allow instance user to put stuff in runtime directory
    # and allow www-data to read from that directory
    sudo chown -R $LAVA_INSTANCE:www-data $LAVA_PREFIX/$LAVA_INSTANCE/run
    sudo chmod -R g+rXs $LAVA_PREFIX/$LAVA_INSTANCE/run
    # Allow instance to log stuff to log directory
    # Allow users in the adm group to read those logs
    sudo chown -R $LAVA_INSTANCE:adm $LAVA_PREFIX/$LAVA_INSTANCE/var/log
    sudo chmod -R g+rXs $LAVA_PREFIX/$LAVA_INSTANCE/var/log
    # Allow instance user to put stuff in temporary directory
    # Set the sticky and setgid bits there
    sudo chgrp -R $LAVA_INSTANCE $LAVA_PREFIX/$LAVA_INSTANCE/tmp
    sudo chmod -R g+rwtXs $LAVA_PREFIX/$LAVA_INSTANCE/tmp

    set +e
    set +x
}


install_venv() {
    LAVA_INSTANCE=$1

    set -e
    set -x

    logger "Creating virtualenv using $LAVA_PYTHON for LAVA instance $LAVA_INSTANCE"

    # Create and enable the virtualenv
    virtualenv --no-site-packages --distribute $LAVA_PREFIX/$LAVA_INSTANCE -p $LAVA_PYTHON
    . $LAVA_PREFIX/$LAVA_INSTANCE/bin/activate

    logger "Installing special version of pip for LAVA instance $LAVA_INSTANCE"

    # Commit a pip-sepukku
    pip uninstall pip --yes

    # Get a special version of pip
    git clone git://github.com/zyga/pip.git -b develop $LAVA_PREFIX/$LAVA_INSTANCE/src/pip

    # Install my version of pip that does not crash on editable bzr branches
    ( cd $LAVA_PREFIX/$LAVA_INSTANCE/src/pip && python setup.py install )

    # Stop using virtualenv
    deactivate

    set +e
    set +x
}


install_database()
{
    LAVA_INSTANCE=$1

    set -e
    set -x

    logger "Creating database configuration for LAVA instance $LAVA_INSTANCE"

    LAVA_PASSWORD=$(dd if=/dev/urandom bs=1 count=128 2>/dev/null | md5sum | cut -d ' ' -f 1)

    # Create database configuration file
    cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/default_database.conf <<DEFAULT_DATABASE_CONF
dbuser='$LAVA_INSTANCE'
dbpass='$LAVA_PASSWORD'
basepath=''
dbname='$LAVA_INSTANCE'
dbserver=''
dbport=''
dbtype='pgsql'
DEFAULT_DATABASE_CONF

    # Create database user
    sudo -u postgres createuser \
        --no-createdb \
        --encrypted \
        --login \
        --no-superuser \
        --no-createrole \
        --no-password \
        $LAVA_INSTANCE

    # Set a password for our new user
    sudo -u postgres psql \
        --quiet \
        --command="ALTER USER \"$LAVA_INSTANCE\" WITH PASSWORD '$LAVA_PASSWORD'"

    # Create a database for our new user
    sudo -u postgres createdb \
        --encoding=UTF-8 \
        --owner=$LAVA_INSTANCE \
        --no-password \
        $LAVA_INSTANCE

    # Install the database adapter
    logger "Installing database adapter for LAVA instance $LAVA_INSTANCE"
    . $LAVA_PREFIX/$LAVA_INSTANCE/bin/activate
    pip install psycopg2

    deactivate
    set +e
    set +x
}


install_web_hosting() {
    LAVA_INSTANCE=$1
    set -e
    set -x

    logger "Installing uWSGI and other hosting parts for LAVA instance $LAVA_INSTANCE"

    . $LAVA_PREFIX/$LAVA_INSTANCE/bin/activate
    pip install uwsgi django-seatbelt django-debian
    deactivate

    if [ \! -e /etc/apache2/mods-available/uwsgi.load ]; then
        logger "Building uWSGI apache module..."
        ( cd $LAVA_PREFIX/$LAVA_INSTANCE/tmp && tar zxf $PIP_DOWNLOAD_CACHE/http%3A%2F%2Fprojects.unbit.it%2Fdownloads%2Fuwsgi-latest.tar.gz )
        ( cd $LAVA_PREFIX/$LAVA_INSTANCE/tmp/uwsgi-$LAVA_UWSGI/apache2 && sudo apxs2 -c -i -a mod_uwsgi.c )
    fi

    cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/lava-server.wsgi <<INSTANCE_WSGI
# This file was automatically generated by lava-deploy-tool.sh
import os
import sys
from django_seatbelt import seatbelt

# We need those to get stuff like threading that seems not to be supported when
# running virtualenv. Despite virtualenv setting up symlinks for some of the
# .so files this one does not seem to work. More insight on if this is really
# the case welcome.
core_python_paths = [
    "/usr/lib/$LAVA_PYTHON",
    "/usr/lib/$LAVA_PYTHON/lib-dynload"]

# Construct new path starting with core python, followed by the rest
sys.path = core_python_paths + [path for path in sys.path if path not in core_python_paths]

# Filter path, allow only core python paths and prefix paths (no local/user/junk)
def allow_core_python(path):
    return path in core_python_paths

# In virtualenv sys.prefix points to the root of the virtualenv, outside it
# points to the prefix of the system python installation (typically /usr)
def allow_sys_prefix(path):
    return path.startswith(sys.prefix)

# seatbelt.solder filters sys.path according to the callbacks specified below.
seatbelt.solder(allow_callbacks=[allow_sys_prefix, allow_core_python])

# Print summary (for debugging)
# print "sys.prefix:", sys.prefix
# print "sys.path:"
# for path in sys.path:
#    print " - %s" % path

# Force django to use the specified settings module.
os.environ['DJANGO_SETTINGS_MODULE'] = 'lava_server.settings.debian'
# And force django-debian to look at our instance-specific configuration directory
os.environ['DJANGO_DEBIAN_SETTINGS_TEMPLATE'] = '$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/{filename}.conf'

# Setup django WSGI handler
import django.core.handlers.wsgi

# NOTE: Here one might also use applications = {'/': application} to define
# namespace mapping. I'm not sure if this is used by uWSGI or by any handler
# but I found that in the docs to uWSGI.
application = django.core.handlers.wsgi.WSGIHandler()
INSTANCE_WSGI

    # Create apache2 site
    cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/apache2/sites-available/lava-server.conf <<INSTANCE_SITE
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    # FIXME: This place needs your help, you should give each instance a custom server name
    ServerName `hostname`

    # Allow serving media, static and other custom files
    <Directory $LAVA_PREFIX/$LAVA_INSTANCE/var/www>
        Options FollowSymLinks
        AllowOverride None
        Order allow,deny
        allow from all
    </Directory>

    # This is a small directory with just the index.html file that tells users
    # about this instance has a link to application pages
    DocumentRoot        $LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server

    # uWSGI mount point. For this to work the uWSGI module needs be loaded.
    # XXX: Perhaps we should just load it ourselves here, dunno.
    <Location />
        SetHandler              uwsgi-handler
        uWSGISocket             $LAVA_PREFIX/$LAVA_INSTANCE/run/uwsgi.sock
    </Location>

    # Make exceptions for static and media.
    # This allows apache to serve those and offload the application server
    <Location /static>
        SetHandler      none
    </Location>
    # We don't need media files as those are private in our implementation

</VirtualHost>
INSTANCE_SITE

    sudo ln -s $LAVA_PREFIX/$LAVA_INSTANCE/etc/apache2/sites-available/lava-server.conf /etc/apache2/sites-available/$LAVA_INSTANCE.conf

    # Create reload file
    echo "Touching this file will gracefully restart uWSGI worker for LAVA instance: $LAVA_INSTANCE" > $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/uwsgi.reload

    # Create uWSGI configuration file
    cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/uwsgi.ini <<UWSGI_INI
[uwsgi]
home = $LAVA_PREFIX/$LAVA_INSTANCE
socket = $LAVA_PREFIX/$LAVA_INSTANCE/run/uwsgi.sock
chmod-socket = 660
wsgi-file = $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/lava-server.wsgi
master = true
workers = 8
logto = $LAVA_PREFIX/$LAVA_INSTANCE/var/log/lava-uwsgi.log
log-master = true
auto-procname = true
touch-reload = $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/uwsgi.reload
UWSGI_INI

    sudo a2ensite $LAVA_INSTANCE.conf
    sudo a2dissite 000-default || true
    sudo service apache2 restart

    set +e
    set +x
}


install_app() {
    LAVA_INSTANCE=$1
    LAVA_REQUIREMENT=$2

    set -e
    set -x

    . $LAVA_PREFIX/$LAVA_INSTANCE/bin/activate
    pip install --upgrade --requirement=$LAVA_REQUIREMENT
    deactivate

    if [ ! -e $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/settings.conf ]; then
        if [ -e $LAVA_PREFIX/$LAVA_INSTANCE/src/lava-server ]; then
            # We're in editable server mode, let's use alternate paths for tempates and static files
            cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/settings.conf <<SETTINGS_CONF
{
    "DEBUG": false,
    "TEMPLATE_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/templates",
        "$LAVA_PREFIX/$LAVA_INSTANCE/src/lava-server/lava_server/templates/"
    ],
    "STATICFILES_DIRS": [
        ["lava-server", "$LAVA_PREFIX/$LAVA_INSTANCE/src/lava-server/lava_server/htdocs/"]
    ],
    "MEDIA_ROOT": "$LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/media",
    "STATIC_ROOT": "$LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/static",
    "MEDIA_URL": "/media/",
    "STATIC_URL": "/static/",
    "DATAREPORT_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/reports"
    ],
    "DATAVIEW_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/views"
    ]
}
SETTINGS_CONF
        else
            cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/settings.conf <<SETTINGS_CONF
{
    "DEBUG": false,
    "TEMPLATE_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/templates",
        "$LAVA_PREFIX/$LAVA_INSTANCE/lib/$LAVA_PYTHON/site-packages/lava_server/templates/"
    ],
    "STATICFILES_DIRS": [
        ["lava-server", "$LAVA_PREFIX/$LAVA_INSTANCE/lib/$LAVA_PYTHON/site-packages/lava_server/htdocs/"]
    ],
    "MEDIA_ROOT": "$LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/media",
    "STATIC_ROOT": "$LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/static",
    "MEDIA_URL": "/media/",
    "STATIC_URL": "/static/",
    "DATAREPORT_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/reports"
    ],
    "DATAVIEW_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/views"
    ]
}
SETTINGS_CONF
    fi
fi
    set +e
    set +x
}


install_config_app() {
    LAVA_INSTANCE=$1

    set -e
    set -x

    # Enable virtualenv
    . $LAVA_PREFIX/$LAVA_INSTANCE/bin/activate

    echo "Building cache of static files..."
    lava-server manage build_static --noinput --link

    echo "Stopping instance for database changes..."
    sudo stop lava-instance LAVA_INSTANCE=$LAVA_INSTANCE || true # in case of upgrades

    echo "Synchronizing database..."
    lava-server manage syncdb --noinput

    echo "Running migrations..."
    lava-server manage migrate --noinput

    # Get out of virtualenv
    deactivate

    echo "Restarting LAVA instance..."
    sudo start lava-instance LAVA_INSTANCE=$LAVA_INSTANCE

    set +e
    set +x
}


cmd_setup() {
    set -e
    SETUP_VER=0
    if [ -e $LAVA_PREFIX/.setup ]; then
        SETUP_VER=$(cat $LAVA_PREFIX/.setup)
    fi


    if [ $SETUP_VER -lt $LAVA_SETUP_REQUIRED_VERSION ]; then
        set +x
        echo "===================="
        echo "LAVA Deployment Tool"
        echo "===================="
        echo
        echo "System preparation steps:"
        echo " 1) Installing $LAVA_PKG_LIST"
        echo " 2) Setting up $LAVA_PREFIX owned by you"
        echo " 3) Setting up $PIP_DOWNLOAD_CACHE for downloads"
        echo " 4) Setting up upstart jobs (incuding removal of stale jobs)"
        echo
        read -p "Type YES to continue: " RESPONSE
        test "$RESPONSE" = 'YES' || return
    
        echo "Updating apt cache..."
        sudo apt-get update

        echo "Installing english language pack, if needed"
        # XXX: I'm not 100% sure this is needed
        sudo apt-get install --yes language-pack-en

        # Use English locale, this is VERY important for PostgreSQL locale settings
        # XXX: I don't like en_US.UTF-8, is there any POSIX.UTF-8 we could use?
        echo "Installing essential packages, if needed"
        LANG=en_US.UTF-8 sudo apt-get install --yes $LAVA_PKG_LIST

        echo "Creating LAVA filesystem in $LAVA_PREFIX"
        sudo mkdir -p $LAVA_PREFIX
        echo "Making $(whoami) the owner of that location"
        sudo chown $(whoami):$(whoami) $LAVA_PREFIX 

        echo "Creating PIP download cache in $PIP_DOWNLOAD_CACHE and making it writable"
        sudo mkdir -p $PIP_DOWNLOAD_CACHE
        sudo chown $(whoami):$(whoami) $PIP_DOWNLOAD_CACHE 

        echo "Creating upstart script for: lava"
        sudo sh -c "cat >/etc/init/lava.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA (abstract task)"

start on runlevel [2345]
stop on runlevel [06]

post-start script
    logger "Started LAVA (all instances)"
end script

post-stop script
    logger "Stopped LAVA (all instances)"
end script
LAVA_CONF

        echo "Creating upstart script for: lava-instances"
        sudo sh -c "cat >/etc/init/lava-instances.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA (instances)"

start on starting lava

task

script
    for dir in \`ls /srv/lava/\`; do
        LAVA_INSTANCE=\`basename \$dir\`
        if [ -e $LAVA_PREFIX/\$LAVA_INSTANCE/etc/lava-server/enabled ]; then
            start lava-instance LAVA_INSTANCE=\$LAVA_INSTANCE
        fi 
    done
end script
LAVA_CONF

        sudo rm -f "/etc/init/lava-uwsgi-workers.conf"

        echo "Creating upstart script for: lava-instance"
        sudo sh -c "cat >/etc/init/lava-instance.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA (instance)"

# Stop when lava is being stopped
stop on stopping lava

# Use LAVA_INSTANCE to differentiate instances
instance \$LAVA_INSTANCE

# Export the instance name so that we can use it in other
# related LAVA jobs.
export LAVA_INSTANCE

pre-start script
    logger "LAVA instance (\$LAVA_INSTANCE) starting..."
end script

post-start script
    logger "LAVA instance (\$LAVA_INSTANCE) started"
end script

pre-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) stopping..."
end script

post-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) stopped"
end script
LAVA_CONF

        sudo rm -f /etc/init/lava-uwsgi-instance.conf

        echo "Creating upstart script for: lava-instance-uwsgi"
        sudo sh -c "cat >/etc/init/lava-instance-uwsgi.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA uWSGI worker"

# This is an instance job, there are many possible workers
# each with different instance variable.
instance \$LAVA_INSTANCE

# Stop and start along with the rest of the instance
start on starting lava-instance
stop on stopping lava-instance

# We want each worker to respawn if it gets hurt.
respawn

# Announce activity 
pre-start script
    logger "LAVA instance (\$LAVA_INSTANCE) uWSGI starting..."
end script

post-start script
    logger "LAVA instance (\$LAVA_INSTANCE) uWSGI started"
end script

pre-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) uWSGI stopping..."
end script

post-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) uWSGI stopped"
end script

# uWSGI wants to be killed with SIGQUIT to indicate shutdown
# NOTE: this is not supported on Lucid (upstart is too old)
# Currently no workaround exists
kill signal SIGQUIT

# Run uWSGI with instance specific configuration file
script
. $LAVA_PREFIX/\$LAVA_INSTANCE/bin/activate
exec sudo -u \$LAVA_INSTANCE VIRTUAL_ENV=\$VIRTUAL_ENV PATH=\$PATH $LAVA_PREFIX/\$LAVA_INSTANCE/bin/uwsgi --ini=$LAVA_PREFIX/\$LAVA_INSTANCE/etc/lava-server/uwsgi.ini
end script
LAVA_CONF

        echo "Removing stale upstart file (if needed): lava-celeryd-instance"
        sudo rm -f /etc/init/lava-celeryd-instance.conf

        echo "Creating upstart script for: lava-instance-celeryd"
        sudo sh -c "cat >/etc/init/lava-instance-celeryd.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA Celery worker"

# This is an instance job, there are many possible workers
# each with different instance variable.
instance \$LAVA_INSTANCE

# Stop and start along with the rest of the instance
start on starting lava-instance
stop on stopping lava-instance

# Respawn the worker if it got hurt
respawn

# Announce workers becoming online
pre-start script
    logger "LAVA instance (\$LAVA_INSTANCE) celery worker starting..."
end script

post-start script
    logger "LAVA instance (\$LAVA_INSTANCE) celery worker started"
end script

pre-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) celery worker stopping..."
end script

post-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) celery worker stopped"
end script

# Some workers can take a while to exit, this should be enough
kill timeout 360

kill signal SIGTERM

# Run celery daemon 
script
. $LAVA_PREFIX/\$LAVA_INSTANCE/bin/activate
exec sudo -u \$LAVA_INSTANCE VIRTUAL_ENV=\$VIRTUAL_ENV PATH=\$PATH $LAVA_PREFIX/\$LAVA_INSTANCE/bin/lava-server manage celeryd --logfile=$LAVA_PREFIX/\$LAVA_INSTANCE/var/log/lava-celeryd.log --loglevel=info --events
end script

LAVA_CONF

        echo "Creating upstart script for: lava-instance-celerybeat"
        sudo sh -c "cat >/etc/init/lava-instance-celerybeat.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA Celery Scheduler"

# This is an instance job, there are many possible workers
# each with different instance variable.
instance \$LAVA_INSTANCE

# Stop and start along with the rest of the instance
start on starting lava-instance
stop on stopping lava-instance

# Respawn the worker if it got hurt
respawn

# Announce workers becoming online
pre-start script
    logger "LAVA instance (\$LAVA_INSTANCE) celery scheduler starting..."
end script

post-start script
    logger "LAVA instance (\$LAVA_INSTANCE) celery scheduler started"
end script

pre-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) celery scheduler stopping..."
end script

post-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) celery scheduler stopped"
end script

# Run celery beat scheduler 
script
. $LAVA_PREFIX/\$LAVA_INSTANCE/bin/activate
exec sudo -u \$LAVA_INSTANCE VIRTUAL_ENV=\$VIRTUAL_ENV PATH=\$PATH $LAVA_PREFIX/\$LAVA_INSTANCE/bin/lava-server manage celerybeat --logfile=$LAVA_PREFIX/\$LAVA_INSTANCE/var/log/lava-celerybeat.log --loglevel=info --pidfile=$LAVA_PREFIX/\$LAVA_INSTANCE/run/lava-celerybeat.pid --schedule=$LAVA_PREFIX/\$LAVA_INSTANCE/var/lib/lava-celery/celerybeat-schedule
end script
LAVA_CONF

        echo "Creating upstart script for: lava-instance-celerycam"
        sudo sh -c "cat >/etc/init/lava-instance-celerycam.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA Celery Camera (worker snapshot service)"

# This is an instance job, there are many possible workers
# each with different instance variable.
instance \$LAVA_INSTANCE

# Stop and start along with the rest of the instance
start on starting lava-instance
stop on stopping lava-instance

# Respawn the worker if it got hurt
respawn

# Announce workers becoming online
pre-start script
    logger "LAVA instance (\$LAVA_INSTANCE) celery cam starting..."
end script

post-start script
    logger "LAVA instance (\$LAVA_INSTANCE) celery cam started"
end script

pre-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) celery cam stopping..."
end script

post-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) celery cam stopped"
end script

# Run celery camera 
script
. $LAVA_PREFIX/\$LAVA_INSTANCE/bin/activate
exec sudo -u \$LAVA_INSTANCE VIRTUAL_ENV=\$VIRTUAL_ENV PATH=\$PATH $LAVA_PREFIX/\$LAVA_INSTANCE/bin/lava-server manage celerycam --logfile=$LAVA_PREFIX/\$LAVA_INSTANCE/var/log/lava-celerycam.log --loglevel=info --pidfile=$LAVA_PREFIX/\$LAVA_INSTANCE/run/lava-celerycam.pid
end script
LAVA_CONF

        echo "Creating upstart script for: lava-instance-scheduler"
        sudo sh -c "cat >/etc/init/lava-instance-scheduler.conf" <<LAVA_CONF
author "Zygmunt Krynicki"
description "LAVA Scheduler"

# This is an instance job, there are many possible workers
# each with different instance variable.
instance \$LAVA_INSTANCE

# Stop and start along with the rest of the instance
start on starting lava-instance
stop on stopping lava-instance

# Respawn the worker if it got hurt
respawn

# Announce workers becoming online
pre-start script
    logger "LAVA instance (\$LAVA_INSTANCE) scheduler starting..."
end script

post-start script
    logger "LAVA instance (\$LAVA_INSTANCE) scheduler started"
end script

pre-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) scheduler stopping..."
end script

post-stop script
    logger "LAVA instance (\$LAVA_INSTANCE) scheduler stopped"
end script

# Run lava scheduler 
script
. $LAVA_PREFIX/\$LAVA_INSTANCE/bin/activate
exec sudo -u \$LAVA_INSTANCE VIRTUAL_ENV=\$VIRTUAL_ENV PATH=\$PATH $LAVA_PREFIX/\$LAVA_INSTANCE/bin/lava-server manage scheduler --logfile=$LAVA_PREFIX/\$LAVA_INSTANCE/var/log/lava-scheduler.log --loglevel=info
end script
LAVA_CONF

        # Store setup version
        echo $LAVA_SETUP_REQUIRED_VERSION > $LAVA_PREFIX/.setup
        echo "Setup complete, you can now install LAVA"
    else
        echo "This step has been already performed"
    fi
    set +e
}


die() {
    echo "$1"
    exit 1
}


cmd_install() {
    LAVA_INSTANCE=${1:-lava}
    LAVA_REQUIREMENT=${2:-requirements.txt}

    if [ \! -e $LAVA_REQUIREMENT ]; then
        wget $LAVA_REQUIREMENT -O remote-requirements.txt || die "Unable to download $LAVA_REQUIREMENT" 
        LAVA_REQUIREMENT=remote-requirements.txt
    fi

    # Sanity checking, ensure that instance does not exist yet
    if [ -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE already exists"
        return
    fi
    install_user $LAVA_INSTANCE || die "Unable to create instance user"
    install_fs $LAVA_INSTANCE || die "Unable to create basic filesystem structure" 
    install_venv $LAVA_INSTANCE || die "Unable to create virtualenv"
    install_database $LAVA_INSTANCE || die "Unable to create database"
    install_web_hosting $LAVA_INSTANCE || die "Unable to create web hosting"
    install_app $LAVA_INSTANCE $LAVA_REQUIREMENT || die "Unable to create application"
    install_config_app $LAVA_INSTANCE || die "Unable to run application postinstall actions"
}


cmd_upgrade() {
    LAVA_INSTANCE=${1:-lava}
    LAVA_REQUIREMENT=${2:-requirements.txt}

    if [ \! -e $LAVA_REQUIREMENT ]; then
        wget $LAVA_REQUIREMENT -O remote-requirements.txt || die "Unable to download $LAVA_REQUIREMENT" 
        LAVA_REQUIREMENT=remote-requirements.txt
    fi

    # Sanity checking, ensure that instance does not exist yet
    if [ \! -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE does not exist"
        return
    fi
    install_app $LAVA_INSTANCE $LAVA_REQUIREMENT || die "Unable to update application"
    install_config_app $LAVA_INSTANCE || die "Unable to run application postinstall actions"
}


cmd_remove() {
    LAVA_INSTANCE=${1:-lava}

    # Sanity checking, ensure that instance exists
    if [ \! -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE does not exist"
        return
    fi
    echo "*** WARNING ***" 
    echo "You are about to IRREVERSIBLY DESTROY the instance $LAVA_INSTANCE"
    echo "There is no automatic backup, there is no way to undo this step"
    echo "*** WARNING ***" 
    echo
    read -p "Type DESTROY to continue: " RESPONSE
    test "$RESPONSE" = 'DESTROY' || return

    set -e
    set -x
    logger "Removing LAVA instance $LAVA_INSTANCE"
    sudo stop lava-instance LAVA_INSTANCE=$LAVA_INSTANCE || true
    sudo rm -f /etc/apache2/sites-available/$LAVA_INSTANCE.conf || true
    sudo rm -f /etc/apache2/sites-enabled/$LAVA_INSTANCE.conf || true
    sudo rm -rf $LAVA_PREFIX/$LAVA_INSTANCE || true
    sudo -u postgres dropdb $LAVA_INSTANCE || true
    sudo -u postgres dropuser $LAVA_INSTANCE || true
    sudo userdel $LAVA_INSTANCE || true
    set +e
    set +x
}


cmd_restore() {
    LAVA_INSTANCE=${1}

    # Sanity checking, ensure that instance exists
    if [ \! -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE does not exist"
        return
    fi

    SNAPSHOT_ID=${2}

    if [ -d "$LAVA_PREFIX/backups/$LAVA_INSTANCE/$SNAPSHOT_ID" ]; then
        SNAPSHOT="$LAVA_PREFIX/backups/$LAVA_INSTANCE/$SNAPSHOT_ID"
    else
        if [ -d "$LAVA_PREFIX/backups/$SNAPSHOT_ID" ]; then
            SNAPSHOT="$LAVA_PREFIX/backups/$SNAPSHOT_ID"
        else
            echo "Cannot find snapshot $SNAPSHOT_ID"
            return
        fi
    fi

    db_snapshot="$SNAPSHOT/database.dump"
    files_snapshot="$SNAPSHOT/files.tar.gz"

    if [ \! -f "$db_snapshot" -o \! -f "$files_snapshot" ]; then
        echo "$SNAPSHOT does not look like a complete snapshot"
        return
    fi

    echo "Are you sure you want to restore instance $LAVA_INSTANCE from"
    echo "SNAPSHOT_ID?  This will DESTROY the existing state of $LAVA_INSTANCE"
    echo
    read -p "Type RESTORE to continue: " RESPONSE
    test "$RESPONSE" = 'RESTORE' || return

    set -e
    set -x

    sudo -u postgres dropdb \
        $LAVA_INSTANCE || true
    sudo -u postgres createdb \
        --encoding=UTF-8 \
        --owner=$LAVA_INSTANCE \
        --no-password \
        $LAVA_INSTANCE
    sudo -u postgres pg_restore \
        --exit-on-error --no-owner \
        --role $LAVA_INSTANCE \
        --dbname $LAVA_INSTANCE \
        $SNAPSHOT/database.dump > /dev/null

    sudo rm -rf $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/
    tar \
        --extract \
        --gzip \
        --directory $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/ \
        --file "$files_snapshot"

    # Allow instance to write to media directory
    sudo chgrp -R $LAVA_INSTANCE $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/
    sudo chmod -R g+rwXs $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/

    set +e
    set +x

    echo "Done"
}

cmd_backup() {
    LAVA_INSTANCE=${1:-lava}

    # Sanity checking, ensure that instance exists
    if [ \! -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE does not exist"
        return
    fi

    echo "Are you sure you want to backup instance $LAVA_INSTANCE"
    echo
    read -p "Type BACKUP to continue: " RESPONSE
    test "$RESPONSE" = 'BACKUP' || return

    # Load database configuration
    . $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/default_database.conf

    # Substitute missing defaults for IP-based connection this works around a bug
    # in postgresql configuration on default Ubuntu installs and allows us to use
    # the ~/.pgpass file.
    test -z "$dbserver" && dbserver=localhost
    test -z "$dbport" && dbport=5432

    snapshot_id=$(TZ=UTC date +%Y-%m-%dT%H-%M-%SZ)

    echo "Making backup with id: $snapshot_id"

    destdir="$LAVA_PREFIX/backups/$LAVA_INSTANCE/$snapshot_id"

    mkdir -p "$destdir"

    echo "Creating database snapshot..."
    PGPASSWORD=$dbpass pg_dump \
        --no-owner \
        --format=custom \
        --host=$dbserver \
        --port=$dbport \
        --username=$dbuser \
        --no-password $dbname \
        --schema=public \
        > "$destdir/database.dump"

    echo "Creating file repository snapshot..."
    tar \
        --create \
        --gzip \
        --directory $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/ \
        --file "$destdir/files.tar.gz" \
        .
    #   ^ There is a DOT HERE don't remove it

    echo "Done"
}

main() {
    os_check
    if [ $LAVA_SUPPORTED = 0 ]; then
        echo "LAVA is not supported on this system"
        echo "------------------------------------"
        echo "Please report a bug on lava-deployment-tool"
        echo "https://bugs.launchpad.net/lava-deployment-tool/+filebug"
        echo
        echo "Please prvide the following information"
        echo 
        lsb_release -a
        exit 1
    fi

    if [ -n "$1" ]; then
        cmd="$1"
        shift
    else
        cmd=help
    fi
    case "$cmd" in
        ^$|help)
            echo "Usage: lava-deployment-tool.sh <command> [options]"
            echo
            echo "Key commands:"
            echo "    setup   - prepare machine for LAVA (prerequisites)"
            echo "    install - install LAVA"
            echo "    upgrade - upgrade LAVA"
            echo
            echo "See the README file for instructions"
            ;;
        setup)
            cmd_setup "$@"
            ;;
        install)
            cmd_install "$@"
            ;;
        backup)
            cmd_backup "$@"
            ;;
        restore)
            cmd_restore "$@"
            ;;
        _remove)
            cmd_remove "$@"
            ;;
        upgrade)
            cmd_upgrade "$@"
            ;;
        install_*)
            $cmd "$@"
            ;;
        *)
            echo "Unknown command: $cmd, try help"
            exit 1
            ;;
    esac
}


main "$@"
