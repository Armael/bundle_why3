open Bos
let (let*) = Result.bind

let rec riter l f = match l with
  | [] -> Ok ()
  | x :: xs ->
    let* () = f x in
    riter xs f

  let is_elf path =
    let* isfile = OS.File.exists path in
    if isfile then begin
      let header = In_channel.with_open_bin (Fpath.to_string path) (fun cin ->
        List.init 4 (fun _ -> In_channel.input_char cin)
      ) in
      Ok (header = [ Some (Char.chr 0x7F); Some 'E'; Some 'L'; Some 'F' ])
    end else
      Ok false

let copy ?mode src dst =
  begin
    let* mode = match mode with
      | None -> OS.Path.Mode.get src
      | Some m -> Ok m
    in
    let* contents = OS.File.read src in
    OS.File.write ~mode dst contents
  end
  |> Result.map_error (fun (`Msg msg) ->
    `Msg (Printf.sprintf "could not copy %s to %s: %s"
            (Fpath.to_string src) (Fpath.to_string dst) msg)
  )

let dynamic_dependencies exe =
  let* ldd_lines =
    OS.Cmd.success @@ OS.Cmd.out_lines @@
    OS.Cmd.run_out Cmd.(v "ldd" % p exe)
  in
  Result.ok @@
  List.filter_map (fun line ->
    let elts =
      String.split_on_char ' ' (String.trim line)
      |> List.filter ((<>) "") in
    match elts with
    | [so_name; "=>"; fullpath; _] ->
      (* XXX: is this reliable? *)
      if so_name = Filename.basename fullpath then
        Some (Fpath.v fullpath)
      else
        None
    | _ ->
      None
  ) ldd_lines

let handle_elf ~outdir bin =
  Format.printf "Adding shared dependencies for %a\n" Fpath.pp bin;

  (* run ldd on the binary, parse its output to get the dependencies *)
  let* dyndeps = dynamic_dependencies bin in

  (* copy the .so dependencies in the lib/ directory *)
  let* () =
    riter dyndeps (fun dep ->
      copy ~mode:0o755 dep Fpath.(outdir / "lib" / basename dep)
    )
  in

  (* use patchelf to set the rpath for the dependencies *)
  let* () =
    riter dyndeps (fun dep ->
      OS.Cmd.success @@ OS.Cmd.out_null @@ OS.Cmd.run_out @@
      Cmd.(v "patchelf"
           % "--set-rpath" % "$ORIGIN"
           % "--force-rpath"
           % p Fpath.(outdir / "lib" / basename dep))
    ) in

  (* use patchelf to set the rpath for the binary *)
  let rel_path_to_lib =
    Fpath.relativize ~root:(Fpath.parent bin) Fpath.(outdir / "lib")
    |> Option.get (* XX *)
  in
  let* () =
    OS.Cmd.success @@ OS.Cmd.out_null @@ OS.Cmd.run_out @@
    Cmd.(v "patchelf"
         % "--set-rpath" % ("$ORIGIN/" ^ Fpath.to_string rel_path_to_lib)
         % "--force-rpath"
         % p bin) in

  (* try to get the interpreter using patchelf *)
  let* () = begin
    match
      OS.Cmd.success @@ OS.Cmd.out_string @@ OS.Cmd.run_out ~err:OS.Cmd.err_null @@
      Cmd.(v "patchelf" % "--print-interpreter" % Fpath.to_string bin)
    with
    | Ok ld_so ->
      (* copy it into interp/ld.so *)
      let ld_so = Fpath.v ld_so in
      copy ~mode:0o755 ld_so Fpath.(outdir / "interp" / "ld.so")
    | Error _ ->
      Result.Ok ()
  end in

  Result.Ok ()


let main () =
  let target, outdir =
    match Sys.argv |> Array.to_list |> List.tl with
    | a :: b :: [] -> a, b
    | _ ->
      Printf.eprintf "usage: %s <directory containing elf files or elf file> <out-dir>\n" Sys.argv.(0);
      exit 1
  in

  let* outdir = OS.Dir.must_exist (Fpath.v outdir) in
  let* _ = OS.Dir.create Fpath.(outdir / "lib") in
  let* _ = OS.Dir.create Fpath.(outdir / "interp") in

  let* target = OS.Path.must_exist (Fpath.v target) in

  if not (Fpath.is_rooted ~root:outdir target) then (
    Format.eprintf "the binary (%a) should be stored inside of the output dir (%a)"
      Fpath.pp target Fpath.pp outdir;
    exit 1
  );

  let* () =
    let* is_file = OS.File.exists target in
    let* is_dir = OS.Dir.exists target in

    if is_file then begin
      handle_elf ~outdir target
    end else if is_dir then begin
      let* res =
        OS.Dir.fold_contents ~elements:(`Sat is_elf) (fun elf acc ->
          let* () = acc in
          handle_elf ~outdir elf
        ) (Result.Ok ()) target
      in
      res
    end else begin
      Format.eprintf "unknown file type %a\n" Fpath.pp target;
      exit 1
    end
  in

  Result.Ok ()

let () =
  match main () with
  | Ok () -> ()
  | Error (`Msg msg) ->
    Printf.eprintf "Error: %s\n" msg;
    exit 1
