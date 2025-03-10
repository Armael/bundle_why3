#!/usr/bin/env bash

SWITCHDIR="$1"
OUTDIR="$2"

# TODO: include why3's version
DMG_NAME="why3-MacOS-$(uname -m)"

# TODO: use _dmg/why3${version} instead
APP_ABSDIR="$OUTDIR/_dmg/why3"
RSRC_ABSDIR="$APP_ABSDIR/Contents/Resources"
BIN_ABSDIR="$RSRC_ABSDIR/bin"
LIB_ABSDIR="$RSRC_ABSDIR/lib"
SHARE_ABSDIR="$RSRC_ABSDIR/share"
DYNLIB_ABSDIR="$RSRC_ABSDIR/lib/dylib"
EXE_ABSDIR="$APP_ABSDIR/Contents/MacOS"

###### Script safety ######

set -o nounset
set -o errexit

##### retry a command (macOS hdiutil is unreliable since a while) #####

# $1 = retry count
# $2 = wait time [s]
# $3.. = command and args

function retry_command()
{
    local maxtries=$1
    local sleeptime=$2
    local cmd="${@: 3}"
    local ntries=0
    echo "retry $maxtries with delay of $sleeptime command '$cmd'"
    while true
    do
        if [ $ntries -ge $maxtries ]
        then
            echo "Max retry count reached -> abort"
            return 1
        fi

        if $cmd
        then
            return 0
        else
            ((ntries++))
            echo "Command failed: $cmd - try $ntries/$maxtries"
            sleep $sleeptime
        fi
    done
}

###### Check if required system utilities are installed #####

# Output some information in case finding macpack needs to be debugged
echo "python3 = '$(which python3)' '$(python3 --version)'"
echo "pip3 = '$(which pip3)' '$(pip3 --version)'"
pip3 show --files macpack

command -v python3 &> /dev/null || ( echo "You don't have python3 - which is strange because macOS supplies one" ; exit 1)
command -v pip3 &> /dev/null || ( echo "You don't have pip3 - which is strange because macOS supplies one" ; exit 1)
command -v gfind &> /dev/null || ( echo "Please install gfind (eg. sudo port install findutils)" ; exit 1)
command -v grealpath &> /dev/null || ( echo "Please install grealpath (eg. sudo port install coreutils)" ; exit 1)

# Determine the path to the macpack binary.
# We filter these two lines from the output of 'pip3 show macpack --files'
# Location: /Users/msoegtrop/Library/Python/3.8/lib/python/site-packages
#   ../../../bin/macpack
# and combine them with realpath to the path to the macpack binary
MACPACK="$(grealpath "$(pip3 show macpack | grep 'Location:' | cut -f 2 -d ' ')/$(pip3 show macpack --files | grep "^[^:]*macpack$" | sed 's/^ *//')")"
echo "MACKPACK = '$MACPACK'"

command -v "$MACPACK"  &> /dev/null || ( echo "Please install macpack (eg. pip3 install macpack)" ; exit 1)

###################### Handle system packages ######################

##### MacPorts/Homebrew folder variables #####

set +e
PORTCMD="$(which port)"
set -e

if [ -z "${PORTCMD}" ]; then
  PKG_MANAGER=brew
  PKG_MANAGER_ROOT="$(brew --cellar)"
  # We want to transform e.g.
  # /opt/homebrew/Cellar/adwaita-icon-theme/46.0/share/icons/Adwaita/cursors/row-resize
  # to
  # share/icons/Adwaita/cursors/row-resize
  PKG_MANAGER_ROOT_STRIP="$(brew --cellar)/*/*/" # one * for the package name and one for its version
else
  PKG_MANAGER=port
  # If someone knows a better way to find out where port is installed, please let me know!
  PKG_MANAGER_ROOT="${PORTCMD%bin/port}"
  PKG_MANAGER_ROOT_STRIP="${PORTCMD%bin/port}"
fi
echo "PKG_MANAGER            = $PKG_MANAGER"
echo "PKG_MANAGER_ROOT       = $PKG_MANAGER_ROOT"
echo "PKG_MANAGER_ROOT_STRIP = $PKG_MANAGER_ROOT_STRIP"

##### Add files from a system package using package name and grep filter #####

# $1 = package name
# $2 = regexp filter (grep)
# Note:
# This function strips common prefixes in the destination.

function add_files_of_system_package {
  case $PKG_MANAGER in
  port)
    LIST_PKG_CONTENTS="port contents"
  ;;
  brew)
    LIST_PKG_CONTENTS="brew ls -v"
  ;;
  esac
  echo "Copying files from package $1 ..."
  echo "Number of files unfiltered $($LIST_PKG_CONTENTS "$1" | wc -l)"
  echo "Number of files filtered $($LIST_PKG_CONTENTS "$1" | grep "$2" | wc -l)"
  for file in $($LIST_PKG_CONTENTS "$1" | grep "$2" | sort -u)
  do
    relpath="${file#"${PKG_MANAGER_ROOT_STRIP}"}"
    reldir="${relpath%/*}"
    echo "add_files_of_system_package '$file' '$RSRC_ABSDIR' '$reldir'"
    mkdir -p "$RSRC_ABSDIR/$reldir"
    cp "$file" "$RSRC_ABSDIR/$reldir/"
  done
}

###################### Handle shared library dependencies ######################

# Find shared library dependencies and patch one binary using macpack
# $1 = full path to executable

function add_shared_library_dependencies {
  type="$(file -b "$1")"
  if [ "${type}" == 'Mach-O 64-bit executable x86_64' ] \
  || [ "${type}" == 'Mach-O 64-bit bundle x86_64' ] \
  || [ "${type}" == 'Mach-O 64-bit dynamically linked shared library x86_64' ] \
  || [ "${type}" == 'Mach-O 64-bit executable arm64' ] \
  || [ "${type}" == 'Mach-O 64-bit bundle arm64' ] \
  || [ "${type}" == 'Mach-O 64-bit dynamically linked shared library arm64' ]
  then
    echo "Adding shared libraries for $1"
    REL_BUNDLE_ROOT_FROM_BIN="$(grealpath --relative-to="$(dirname "$1")" "$RSRC_ABSDIR")"
    "${MACPACK}" -v -d "$REL_BUNDLE_ROOT_FROM_BIN"/lib/dylib "$1" >> logs/macpack.log
  else
    echo "INFO: File '$1' with type '${type}' ignored in shared library analysis."
  fi
}

# Same but takes a directory as argument, and applies add
# shared_library_dependencies to all its binaries
# $1 = full path to the directory

function add_shared_library_dependencies_dir {
    for file in $(gfind "$1" -type f)
    do
      add_shared_library_dependencies "${file}"
    done
}

###################### Adding stuff manually ######################

##### Add a single file #####

# $1 = path prefix (absolute)
# $2 = relative path to $1 and ${RSRC_ABSDIR}
# $3 = file name

function add_single_file {
  echo "Copying single file $1/$2/$3"
  mkdir -p "${RSRC_ABSDIR}/$2"
  cp "$1/$2/$3" "${RSRC_ABSDIR}/$2/"
}

##### Create the bundle folder structure #####

mkdir -p ${APP_ABSDIR}
mkdir -p ${RSRC_ABSDIR}
mkdir -p ${DYNLIB_ABSDIR}
mkdir -p ${BIN_ABSDIR}
mkdir -p ${EXE_ABSDIR}
mkdir -p ${SHARE_ABSDIR}

##### Copy the main why3 binary

cp "$SWITCHDIR/bin/why3" "$BIN_ABSDIR/"
cp -r "$SWITCHDIR/lib/why3" "$LIB_ABSDIR/"
cp -r "$SWITCHDIR/share/why3" "$SHARE_ABSDIR/"

##### Copy dynamically loaded (invisible for 'otool') shared libraries for GDK and GTK #####

INSTALL_DIR_PLACEHOLDER="PATCHMEPATCHME"

PIXBUF_LOADER_ABSDIR="$RSRC_ABSDIR/lib/gdk-pixbuf-2.0/2.10.0/loaders"
mkdir -p "$PIXBUF_LOADER_ABSDIR"
for file in $(gdk-pixbuf-query-loaders | grep '/loaders/libpixbufloader-' | sed s/\"//g); do
  cp "${file}" "$PIXBUF_LOADER_ABSDIR/"
done

# the paths are absolute and need to be adjusted to their final path
(cd "$PIXBUF_LOADER_ABSDIR/"; \
 GDK_PIXBUF_MODULEDIR=. gdk-pixbuf-query-loaders | \
   sed "s|^\"\\./|\"$INSTALL_DIR_PLACEHOLDER/resources/lib/gdk-pixbuf-2.0/2.10.0/loaders/|" > ../loaders.cache)

IMMODULES_ABSDIR="$RSRC_ABSDIR/lib/gtk-3.0/3.0.0/immodules"
mkdir -p "$IMMODULES_ABSDIR"
for file in $(gtk-query-immodules-3.0 | grep /im- | sed s/\"//g); do
  cp "${file}" "$IMMODULES_ABSDIR"
done

# the paths are absolute and need to be adjusted to their final path
(cd "$IMMODULES_ABSDIR/"; \
 gtk-query-immodules-3.0 | \
   sed "s|^\".*/immodules/|\"$INSTALL_DIR_PLACEHOLDER/resources/lib/gtk-3.0/3.0.0/immodules/|" > ../immodules.cache)

##### Import dynamic dependencies for why3 and the GTK/GDK libraries

add_shared_library_dependencies "$BIN_ABSDIR/why3"

add_shared_library_dependencies_dir "$LIB_ABSDIR/why3"

add_shared_library_dependencies_dir "$PIXBUF_LOADER_ABSDIR"

add_shared_library_dependencies_dir "$IMMODULES_ABSDIR"

##### Add GTK resources

### Adwaita icon theme

add_files_of_system_package "adwaita-icon-theme"  \
"index.theme\|/\(16x16\|scalable\|symbolic\)/.*\("\
"actions/bookmark\|actions/document\|devices/drive\|actions/format-text\|actions/go\|actions/list\|"\
"actions/media\|actions/pan\|actions/process\|actions/system\|actions/window\|"\
"mimetypes/text\|mimetypes/inode\|mimetypes/application\|"\
"places/folder\|places/user\|status/dialog\|ui/pan\|"\
"legacy/document\|legacy/go\|legacy/process\|legacy/window\|legacy/system\)" \

### GTK compiled schemas

case $PKG_MANAGER in
  port)
    add_single_file "${PKG_MANAGER_ROOT}" "share/glib-2.0/schemas" "gschemas.compiled"
  ;;
  brew)
    oneschema="$(brew ls -v gtk+3 | grep /schemas/ | head -1)"
    schemapath="${oneschema%"${oneschema##*/schemas/}"}"
    gtkroot="${schemapath%/share/glib-2.0/schemas/}"
    echo "GTK schema paths: $oneschema, $schemapath, $gtkroot"
    glib-compile-schemas "$schemapath"
    add_single_file "${gtkroot}" "share/glib-2.0/schemas" "gschemas.compiled"
  ;;
esac

### GTK sourceview language specs and styles

add_files_of_system_package gtksourceview3 "/share/gtksourceview-3.0/"

##### Create wrapper executable to start why3 with the correct environment

cc wrapper.c -o "$EXE_ABSDIR/why3"
chmod a+x "$EXE_ABSDIR/why3"

##### Create relocation binary to run after unpacking the bundle

# TODO should this be a separate binary and where
cc relocate.c -o "$BIN_ABSDIR/relocate"
chmod a+x "$BIN_ABSDIR/relocate"

###################### Create contents of the top level DMG folder  ######################

##### Link to the Applications folder #####

# Create a link to the 'Applications' folder, so that one can drag and drop the application there

# TODO: do we need this?

ln -sf /Applications _dmg/Applications

###################### CREATE INSTALLER ######################

##### Create DMG image from folder #####

echo '##### Create DMG image #####'

hdi_opts=(-volname "${DMG_NAME}"
          -srcfolder _dmg
          -ov # overwrite existing file
          ${ZIPCOMPR}
          # needed for backward compat since macOS 10.14 which uses APFS by default
          # see discussion in #11803
          -fs hfs+
         )

retry_command 10 3 hdiutil create "${hdi_opts[@]}" "${DMG_NAME}.dmg"

echo "##### Finished installer '${DMG_NAME}.dmg' #####"
