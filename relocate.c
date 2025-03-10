#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <sys/stat.h>
#include <assert.h>
#include <errno.h>

#ifdef __APPLE__
#include <libproc.h>
#endif

#ifdef __APPLE__
#define PATH_MAXSIZE PROC_PIDPATHINFO_MAXSIZE
#else
#define PATH_MAXSIZE 5000
#endif

char* interp_patch_pattern(void) {
  char* patch = calloc(32*8 + 1, sizeof(char));
  for(int i = 0; i < 32; i++) {
    strcat(patch, "DEADBEEF");
  }
  return patch;
}

void patch_file(char* filename, char* patch_str, char* newpath, int add_padding) {
  fprintf(stderr, "patch %s with path %s\n", filename, newpath);
  int patches = 0;

  FILE* fin;
  FILE* fout;

  size_t filename_out_len = strlen(filename) + 5;
  char* filename_out = (char*)calloc(filename_out_len, sizeof(char));
  strncpy(filename_out, filename, filename_out_len-1);
  strncat(filename_out, ".tmp", filename_out_len-1);

  if ((fin = fopen(filename, "r")) == NULL) {
    fprintf(stderr, "relocate: cannot open %s for reading\n", filename);
    exit(1);
  }

  if ((fout = fopen(filename_out, "w")) == NULL) {
    fprintf(stderr, "relocate: cannot open %s for writing\n", filename_out);
    exit(1);
  }

  char* line = NULL;
  size_t len = 0;
  ssize_t read;
  while ((read = getline(&line, &len, fin)) != -1) {
    char* patch_start;
    if ((patch_start = memmem(line, read, patch_str, strlen(patch_str))) != NULL) {
      size_t patch_off = patch_start - line;
      patches++;
      // prefix
      fwrite(line, sizeof(char), patch_off, fout);
      // patch replacement
      fwrite(newpath, sizeof(char), strlen(newpath), fout);
      if (add_padding) {
        // pad with 0s to keep the same number of bytes
        assert (strlen(newpath) < strlen(patch_str));
        fwrite("\0", sizeof(char), strlen(patch_str) - strlen(newpath), fout);
      }
      // remaining of the line
      fwrite(line + patch_off + strlen(patch_str),
             sizeof(char),
             read - (patch_off + strlen(patch_str)),
             fout);
    } else {
      fwrite(line, sizeof(char), read, fout);
    }
  }

  fclose(fin);
  fclose(fout);
  if(line) free(line);

  struct stat sb;
  stat(filename, &sb);

  rename(filename_out, filename);
  chmod(filename, sb.st_mode);

  fprintf(stderr, "applied the patch %d times\n", patches);
}

int main (int argc, char* argv[]) {
  char bin_path[PATH_MAXSIZE];
  char resources_folder[PATH_MAXSIZE];
  char tmp[PATH_MAXSIZE];

#ifdef __APPLE__
  if(proc_pidpath(getpid(), bin_path, sizeof(bin_path))<=0) {
    fprintf(stderr, "why3 wrapper: error in proc_pidpath: %s\n", strerror(errno));
    exit(1);
  }
#else
  if (readlink("/proc/self/exe", bin_path, PATH_MAXSIZE-1) <= 0) {
    fprintf(stderr, "relocate: error in readlink /proc/self/exe\n");
    exit(1);
  }
  bin_path[PATH_MAXSIZE] = '\0';
#endif

#ifdef __APPLE__
  // [bin_path] is of the form: /.../bundle/Contents/Resources/bin/relocate
  char bin_folder[PATH_MAXSIZE];
  char macos_folder[PATH_MAXSIZE];
  char contents_folder[PATH_MAXSIZE];
  strncpy(bin_folder, dirname(bin_path), sizeof(bin_folder)-1);
  // [resources_folder]: /.../bundle/Contents/Resources
  strncpy(resources_folder, dirname(bin_folder), sizeof(resources_folder)-1);
#else
  char bin_folder[PATH_MAXSIZE];
  char bundle_folder[PATH_MAXSIZE];
  // [bin_path] is of the form: /.../bundle/bin/relocate
  strncpy(bin_folder, dirname(bin_path), sizeof(bin_folder)-1);
  strncpy(bundle_folder, dirname(bin_folder), sizeof(bundle_folder)-1);
  // [resources_folder]: /.../bundle/resources
  strncpy(resources_folder, bundle_folder, sizeof(resources_folder)-1);
  strncat(resources_folder, "/resources", sizeof(resources_folder)-1);
#endif

  strncpy(tmp, resources_folder, sizeof(tmp)-1);
  strncat(tmp, "/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache", sizeof(tmp)-1);
  patch_file(tmp, "PATCHMEPATCHME", resources_folder, 0);

  strncpy(tmp, resources_folder, sizeof(tmp)-1);
  strncat(tmp, "/lib/gtk-3.0/3.0.0/immodules.cache", sizeof(tmp)-1);
  patch_file(tmp, "PATCHMEPATCHME", resources_folder, 0);

#ifndef __APPLE__
  char interp_path[PATH_MAXSIZE];
  // /.../bundle/interp/ld.so
  strncpy(interp_path, bundle_folder, sizeof(interp_path)-1);
  strncat(interp_path, "/interp/ld.so", sizeof(interp_path)-1);

  strncpy(tmp, bundle_folder, sizeof(tmp)-1);
  strncat(tmp, "/bin/why3", sizeof(tmp)-1);
  char* patch = interp_patch_pattern();
  patch_file(tmp, patch, interp_path, 1);
  free(patch);
#endif
}
