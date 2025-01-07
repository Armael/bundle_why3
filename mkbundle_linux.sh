#!/usr/bin/env bash

set -euo pipefail

# source utilities.sh

SWITCHDIR="$1"
OUTDIR="$2"

BIN_ABSDIR="$OUTDIR/bin"
EXE_ABSDIR="$OUTDIR/exe"
LIB_ABSDIR="$OUTDIR/lib"
SHARE_ABSDIR="$OUTDIR/share"
RSRC_ABSDIR="$OUTDIR/resources"

INSTALL_DIR_PLACEHOLDER="PATCHMEPATCHME"

function interp_patch_pattern {
    patch=""
    for i in $(seq 1 32); do
        patch="$patch""DEADBEEF"
    done;
    echo $patch
}

function add_shared_library_dependencies {
  "$SWITCHDIR/bin/bundle_tool" "$1" "$OUTDIR"
}

##### Add a single file #####

# $1 = path prefix (absolute)
# $2 = relative path to $1 and ${RSRC_ABSDIR}
# $3 = file name

function add_single_file {
  echo "Copying single file $1/$2/$3"
  mkdir -p "${RSRC_ABSDIR}/$2"
  cp "$1/$2/$3" "${RSRC_ABSDIR}/$2/"
}

##### Add files from a system package using package name and grep filter #####

# $1 = package name
# $2 = regexp filter (grep)
# Note:
# This function strips common prefixes in the destination.

LIST_PKG_CONTENTS="pacman -Ql"
PKG_MANAGER_ROOT_STRIP="/usr"

function add_files_of_system_package {
  echo "Copying files from package $1 ..."
  echo "Number of files unfiltered $($LIST_PKG_CONTENTS "$1" | wc -l)"
  echo "Number of files filtered $($LIST_PKG_CONTENTS "$1" | grep "$2" | wc -l)"
  for file in $($LIST_PKG_CONTENTS "$1" | grep "$2" | sort -u)
  do
      if [ -f "$file" ]; then
          relpath="${file#"${PKG_MANAGER_ROOT_STRIP}"}"
          reldir="${relpath%/*}"
          echo "add_files_of_system_package '$file' '$RSRC_ABSDIR' '$reldir'"
          mkdir -p "$RSRC_ABSDIR/$reldir"
          cp "$file" "$RSRC_ABSDIR/$reldir/"
      fi
  done
}

##### Create the bundle folder structure #####

mkdir "$OUTDIR"
mkdir -p "$BIN_ABSDIR"
mkdir -p "$EXE_ABSDIR"
mkdir -p "$LIB_ABSDIR"
mkdir -p "$SHARE_ABSDIR"
mkdir -p "$RSRC_ABSDIR"

##### Copy the main why3 binary

cp "$SWITCHDIR/bin/why3" "$EXE_ABSDIR/"
cp -r "$SWITCHDIR/lib/why3" "$LIB_ABSDIR/"
cp -r "$SWITCHDIR/share/why3" "$SHARE_ABSDIR/"

##### Copy dynamically loaded (invisible for ldd) shared libraries for GDK and GTK

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

add_shared_library_dependencies "$EXE_ABSDIR/why3"
patchelf --set-interpreter "$(interp_patch_pattern)" "$EXE_ABSDIR/why3"

add_shared_library_dependencies "$LIB_ABSDIR/why3"

add_shared_library_dependencies "$PIXBUF_LOADER_ABSDIR"

add_shared_library_dependencies "$IMMODULES_ABSDIR"

##### Add GTK resources

### Adwaita icon theme

add_files_of_system_package "adwaita-icon-theme"  \
"index.theme\|/\(16x16\|scalable\|symbolic\)/.*\("\
"actions/bookmark\|actions/document\|devices/drive\|actions/format-text\|actions/go\|actions/list\|"\
"actions/media\|actions/pan\|actions/process\|actions/system\|actions/window\|"\
"mimetypes/text\|mimetypes/inode\|mimetypes/application\|"\
"places/folder\|places/user\|status/dialog\|ui/pan\|"\
"legacy/document\|legacy/go\|legacy/process\|legacy/window\|legacy/system\)" \

# make_theme_index "${RSRC_ABSDIR}/share/icons/Adwaita/"

### GTK compiled schemas

add_single_file "/usr" "share/glib-2.0/schemas" "gschemas.compiled"

### GTK sourceview language specs and styles

add_files_of_system_package gtksourceview3 "/share/gtksourceview-3.0/"

### Include the mime database

add_files_of_system_package shared-mime-info "/share/mime/"
# pass a matching XDG_DATA_HOME to avoid getting a warning from the command
XDG_DATA_HOME="$RSRC_ABSDIR/share" update-mime-database "$RSRC_ABSDIR/share/mime"

### Include some fonts: cantarell and noto{Sans,SansMono}

add_files_of_system_package cantarell-fonts "/share/fonts/"
add_files_of_system_package noto-fonts "/share/fonts/noto/NotoSans-\|/share/fonts/noto/NotoSansMono-"

### Include fonts.conf for the rare cases where fontconfig is not present

mkdir -p "$RSRC_ABSDIR/etc/fonts"
cp fonts.conf "$RSRC_ABSDIR/etc/fonts/"

##### Create wrapper executable to start why3 with the correct ld.so and environment

cc -static wrapper.c -o "$BIN_ABSDIR/why3"
chmod a+x "$BIN_ABSDIR/why3"

##### Create relocation binary to run after unpacking the bundle

cc -static relocate.c -o "$EXE_ABSDIR/relocate"
chmod a+x "$EXE_ABSDIR/relocate"
