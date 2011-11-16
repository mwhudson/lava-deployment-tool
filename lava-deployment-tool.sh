#!/bin/sh

# Global Configuration

# All LAVA instances are created relative to this path
LAVA_PREFIX=/srv/lava
# All LAVA uses this python version
LAVA_PYTHON=python2.6
# All of LAVA is being served by this uWSGI version
LAVA_UWSGI=0.9.9.2
# Required system packages
LAVA_PKG_LIST="python-virtualenv build-essential $LAVA_PYTHON-dev libxml2-dev apache2 apache2-dev postgresql"

# Helper to run pip
PIP="$LAVA_PYTHON `which pip`"


rm_instance() {
    LAVA_INSTANCE=$1
    sudo rm -f /etc/apache2/sites-available/$LAVA_INSTANCE.conf
    sudo rm -f /etc/apache2/sites-enabled/$LAVA_INSTANCE.conf
    sudo rm -rf $LAVA_INSTANCE
    sudo -u postgres dropdb $LAVA_INSTANCE || true
    sudo -u postgres dropuser $LAVA_INSTANCE || true
}


postinstall_app() {
    LAVA_INSTANCE=$1

    echo "Synchronizing database..."
    $LAVA_PREFIX/$LAVA_INSTANCE/bin/lava-server manage \
        --production \
        --instance=$LAVA_INSTANCE \
        --instance-template=$LAVA_PREFIX/{instance}/etc/lava-server/{{filename}}.conf \
        syncdb --noinput

    echo "Running migrations..."
    $LAVA_PREFIX/$LAVA_INSTANCE/bin/lava-server manage \
        --production \
        --instance=$LAVA_INSTANCE \
        --instance-template=$LAVA_PREFIX/{instance}/etc/lava-server/{{filename}}.conf \
        migrate --noinput

    echo "Building cache of static files..."
    $LAVA_PREFIX/$LAVA_INSTANCE/bin/lava-server manage \
        --production \
        --instance=$LAVA_INSTANCE \
        --instance-template=$LAVA_PREFIX/{instance}/etc/lava-server/{{filename}}.conf \
        build_static --noinput --link
}


install_fs() {
    LAVA_INSTANCE=$1

    # Create basic directory structure
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/apache2/sites-available
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/reports
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/views
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/templates
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/media
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/lib/lava-server/static
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/www/
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/var/log/
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/src
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/tmp/build
    mkdir -p $LAVA_PREFIX/$LAVA_INSTANCE/tmp/download
}


install_venv() {
    LAVA_INSTANCE=$1

    # Create and enable the virtualenv
    virtualenv --no-site-packages --distribute $LAVA_PREFIX/$LAVA_INSTANCE -p $LAVA_PYTHON
}


install_database()
{
    LAVA_INSTANCE=$1

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

    # Prepare pip cache
    export PIP_DOWNLOAD_CACHE=$LAVA_PREFIX/$LAVA_INSTANCE/tmp/download

    $PIP install --environment=$LAVA_PREFIX/$LAVA_INSTANCE \
        --src=$LAVA_PREFIX/$LAVA_INSTANCE/tmp/download/ \
        psycopg2
}


install_app() {
    LAVA_INSTANCE=$1
    LAVA_PREQUIREMENT=$2

    # Prepare pip cache
    export PIP_DOWNLOAD_CACHE=$LAVA_PREFIX/$LAVA_INSTANCE/tmp/download

    $PIP install --upgrade --environment=$LAVA_PREFIX/$LAVA_INSTANCE --src=$LAVA_PREFIX/$LAVA_INSTANCE/tmp/download/ --requirement=$LAVA_REQUIREMENT

    if [ ! -e $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/settings.conf ]; then
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
    "MEDIA_ROOT": "$LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/media",
    "STATIC_ROOT": "$LAVA_PREFIX/$LAVA_INSTANCE/var/www/lava-server/static",
    "DATAREPORT_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/reports"
    ],
    "DATAVIEW_DIRS": [
        "$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/views"
    ]
}
SETTINGS_CONF
fi
}


install_web_hosting() {
    LAVA_INSTANCE=$1

    # Prepare pip cache
    export PIP_DOWNLOAD_CACHE=$LAVA_PREFIX/$LAVA_INSTANCE/tmp/download

    echo "Installing uWSGI and other hosting parts..."
    $PIP install --environment=$LAVA_PREFIX/$LAVA_INSTANCE \
        --src=$LAVA_PREFIX/$LAVA_INSTANCE/tmp/download/ \
        uwsgi django-seatbelt django-debian

    if [ \! -e /etc/apache2/mods-available/uwsgi.load ]; then
        echo "Building uWSGI apache module..."
        ( cd $LAVA_PREFIX/$LAVA_INSTANCE/tmp/build && tar zxf ../download/http%3A%2F%2Fprojects.unbit.it%2Fdownloads%2Fuwsgi-latest.tar.gz )
        ( cd $LAVA_PREFIX/$LAVA_INSTANCE/tmp/build/uwsgi-$LAVA_UWSGI/apache2 && sudo apxs2 -c -i -a mod_uwsgi.c )
    fi

    echo "Creating WSGI file..."
    cat $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/lava-server.wsgi <<INSTANCE_WSGI
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

    # Create apache2 sitee
    cat $LAVA_PREFIX/$LAVA_INSTANCE/etc/apache2/sites-available/lava-server.conf <<INSTANCE_SITE
<VirtualHost *:80>
    ServerAdmin webmaster@localhost

    # Allow serving media, static and other custom files
    <Directory $LAVA_PREFIX/$LAVA_INSTANCE/var/www>
        Options FollowSymLinks
        AllowOverride None
        Order allow,deny
        allow from all
    </Directory>

    # This is a small directory with just the index.html file that tells users
    # about this instance has a link to application pages
    DocumentRoot        $LAVA_PREFIX/$LAVA_INSTANCE/var/www

    # uWSGI mount point. For this to work the uWSGI module needs be loaded.
    # XXX: Perhaps we should just load it ourselves here, dunno.
    <Location /$LAVA_INSTANCE>
        SetHandler              uwsgi-handler
        uWSGISocket             $LAVA_PREFIX/$LAVA_INSTANCE/uwsgi.sock
        uWSGIForceScriptName    /$LAVA_INSTANCE
    </Location>

    # Make exceptions for static and media.
    # This allows apache to serve those and offload the application server
    <Location /$LAVA_INSTANCE/static>
        SetHandler      none
    </Location>
    <Location /$LAVA_INSTANCE/media>
        SetHandler      none
    </Location>

</VirtualHost>
INSTANCE_SITE

    # Create uWSGI confguration file
    cat >$LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/uwsgi.ini <<UWSGI_INI
[uwsgi]
home = $LAVA_PREFIX/$LAVA_INSTANCE
socket = $LAVA_PREFIX/$LAVA_INSTANCE/uwsgi.sock
chmod-socket = 666
wsgi-file = $LAVA_PREFIX/$LAVA_INSTANCE/etc/lava-server/lava-server.wsgi
uid = www-data
gid = www-data
master = true
logto = $LAVA_PREFIX/$LAVA_INSTANCE/var/log/lava-server.log
UWSGI_INI

    echo "Creating symlink for apache site"
    sudo ln -s $LAVA_PREFIX/$LAVA_INSTANCE/etc/apache2/sites-available/lava-server.conf /etc/apache2/sites-available/$LAVA_INSTANCE.conf

    sudo a2ensite $LAVA_INSTANCE.conf
}


cmd_setup() {
    echo "Welcome to LAVA setup utility"
    echo "This step will install several packages on your system"
    echo "Type yes to continue"
    echo
    read -p "Do you want to continue: " RESPONSE
    test "$RESPONSE" = 'yes' || return
    # Install global deps if missing
    sudo apt-get update
    # I'm not 100% sure this is needed
    sudo apt-get install --yes language-pack-en
    # Use english locale, this is VERY important for postgresql locale settings
    # XXX: I don't like en_US.UTF-8, is there any POSIX.UTF-8 we could use?
    LANG=en_US.UTF-8 sudo apt-get install --yes $LAVA_PKG_LIST
    # Make prefix writable
    sudo mkdir -p $LAVA_PREFIX 
    sudo chown $(whoami):$(whoami) $LAVA_PREFIX 
    echo "Setup complete, you can now install LAVA"
}


cmd_install() {
    LAVA_INSTANCE=lava
    LAVA_REQUIREMENT=requirements.txt

    # Sanity checking, ensure that instance does not exist yet
    if [ -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE already exists"
        return
    fi
    install_fs $LAVA_INSTANCE 
    install_venv $LAVA_INSTANCE 
    install_database $LAVA_INSTANCE
    install_web_hosting $LAVA_INSTANCE
    install_app $LAVA_INSTANCE $LAVA_REQUIREMENT 
    postinstall_app $LAVA_INSTANCE
}


cmd_upgrade() {
    LAVA_INSTANCE=lava

    # Sanity checking, ensure that instance does not exist yet
    if [ \! -d "$LAVA_PREFIX/$LAVA_INSTANCE" ]; then
        echo "Instance $LAVA_INSTANCE does not exist"
        return
    fi
    install_app $LAVA_INSTANCE $LAVA_REQUIREMENT 
    postinstall_app $LAVA_INSTANCE
}


main() {
    if [ -n "$1" ]; then
        cmd="$1"
        shift
    else
        cmd=help
    fi
    case "$cmd" in
        ^$|help)
            echo "Usage: lava-deplyoment-tool.sh <command> [options]"
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
        upgrade)
            cmd_upgrade "$@"
            ;;
        *)
            echo "Unknown command: $cmd, try help"
            exit 1
            ;;
    esac
}


main "$@"
