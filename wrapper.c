#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <errno.h>

#ifdef __APPLE__
#include <libproc.h>
#include <spawn.h>
#endif

#ifdef __APPLE__
#define PATH_MAXSIZE PROC_PIDPATHINFO_MAXSIZE
#else
#define PATH_MAXSIZE 5000
#endif

int main (int argc, char* argv[]) {
  char bin_path[PATH_MAXSIZE];
  char resources_folder[PATH_MAXSIZE];
  char why3_path[PATH_MAXSIZE];
  char tmp[PATH_MAXSIZE];

#ifdef __APPLE__
  if(proc_pidpath(getpid(), bin_path, sizeof(bin_path))<=0) {
    fprintf(stderr, "why3 wrapper: error in proc_pidpath: %s\n", strerror(errno));
    exit(1);
  }
#else
  if (readlink("/proc/self/exe", bin_path, PATH_MAXSIZE-1) <= 0) {
    fprintf(stderr, "why3 wrapper: error in readlink /proc/self/exe\n");
    exit(1);
  }
  bin_path[PATH_MAXSIZE] = '\0';
#endif

#ifdef __APPLE__
  // [bin_path] is of the form: /.../bundle/Contents/MacOS/why3
  char macos_folder[PATH_MAXSIZE];
  char contents_folder[PATH_MAXSIZE];
  strncpy(macos_folder, dirname(bin_path), sizeof(macos_folder)-1);
  strncpy(contents_folder, dirname(macos_folder), sizeof(contents_folder)-1);

  // [resources_folder]: /.../bundle/Contents/Resources
  strncpy(resources_folder, contents_folder, sizeof(resources_folder)-1);
  strncat(resources_folder, "/Resources", sizeof(resources_folder)-1);

  // [why3_path]: /.../bundle/Contents/Resources/bin/why3
  strncpy(why3_path, resources_folder, sizeof(why3_path)-1);
  strncat(why3_path, "/bin/why3", sizeof(why3_path)-1);
#else
  // [bin_path] is of the form: /.../bundle/exe/why3
  char exe_folder[PATH_MAXSIZE];
  char bundle_folder[PATH_MAXSIZE];
  strncpy(exe_folder, dirname(bin_path), sizeof(exe_folder)-1);
  strncpy(bundle_folder, dirname(exe_folder), sizeof(bundle_folder)-1);

  // [resources_folder]: /.../bundle/resources
  strncpy(resources_folder, bundle_folder, sizeof(resources_folder)-1);
  strncat(resources_folder, "/resources", sizeof(resources_folder)-1);

  // [why3_path]: /.../bundle/bin/why3
  strncpy(why3_path, bundle_folder, sizeof(why3_path)-1);
  strncat(why3_path, "/bin/why3", sizeof(why3_path)-1);
#endif

  // Generate and set GDK_PIXBUF_MODULE_FILE
  strncpy(tmp, resources_folder, sizeof(tmp)-1);
  strncat(tmp, "/lib/gdk-pixbuf-2.0/2.10.0/loaders/loaders.cache", sizeof(tmp)-1);
  setenv("GDK_PIXBUF_MODULE_FILE", tmp, 1);

  // Generate and set GTK_IM_MODULE_FILE
  strncpy(tmp, resources_folder, sizeof(tmp)-1);
  strncat(tmp, "/lib/3.0/3.0.0/immodules.cache", sizeof(tmp)-1);
  setenv("GTK_IM_MODULE_FILE", tmp, 1);

  // Generate and set XDG_DATA_HOME
  strncpy(tmp, resources_folder, sizeof(tmp)-1);
  strncat(tmp, "/share", sizeof(tmp)-1);
  setenv("XDG_DATA_HOME", tmp, 1);

#ifndef __APPLE__
  // Generate and set FONTCONFIG_PATH
  strncpy(tmp, resources_folder, sizeof(tmp)-1);
  strncat(tmp, "/etc/fonts", sizeof(tmp)-1);
  setenv("FONTCONFIG_PATH", tmp, 1);
#endif

  // call executable
  char** newargs = (char**)calloc(argc+1, sizeof(char*));
  for(int i = 0; i < argc; i++) newargs[i] = argv[i];
  newargs[0] = why3_path;
  newargs[argc] = 0;
  execv(why3_path, newargs);
  fprintf(stderr, "execv failed calling %s\n", why3_path);
  perror("Error message: ");
}
