#!/bin/sh
# Usage:
#   ./wine-strace.sh <app.exe>           # auto-trace all exes + clean prefix + clean system Wine
#   ./wine-strace.sh <trace-file>        # use pre-recorded trace + clean prefix + clean system Wine
#
# Finds all .exe files in the app directory, traces each one with
# WINEDEBUG=+loaddll, and keeps only .dll/.exe/.drv/.sys stubs that
# were actually loaded. Also uses objdump for direct imports and a
# POSIX PE parser for delay-load imports.
# Always keeps winsxs, system.ini, and registry.
# Also cleans system Wine builtins in /usr/lib/wine/ if present.
#
# Environment variables:
#   WINE_STRACE_TIME         Seconds to trace each exe (default: 15)
#   WINE_STRACE_BINARY       Space-separated exe names to trace (default: all found)
#   WINE_STRACE_FLAGS        Arguments passed to the traced exes

_echo() {
	printf '\033[1;92m%s\033[0m\n' " $*"
}

_err_msg() {
	>&2 printf '\033[1;31m%s\033[0m\n' " $*"
}

_is_cmd() {
	for cmd do
		command -v "$cmd" 1>/dev/null || return 1
	done
	return 0
}

DEPENDENCIES="
	awk
	basename
	cut
	dd
	dirname
	find
	grep
	head
	kill
	mktemp
	od
	readlink
	sed
	sleep
	sort
	stat
	tr
	wc
	wine
"

_sanity_check() {
	for d in $DEPENDENCIES; do
		if ! _is_cmd "$d"; then
			_err_msg "ERROR: Missing dependency '$d'!"
			exit 1
		fi
	done
}

_sanity_check

if [ $# -lt 1 ]; then
	_err_msg "USAGE: $0 <trace-file|app.exe>"
	exit 1
fi

WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
WINE_STRACE_TIME=${WINE_STRACE_TIME:-${STRACE_TIME:-15}}
WINE_STRACE_BINARY=${WINE_STRACE_BINARY:-$STRACE_BINARY}
WINE_STRACE_FLAGS=${WINE_STRACE_FLAGS:-$STRACE_FLAGS}
exe_path=""
all_exes=""
trace=""

# Map Windows drive letter to Linux path prefix
map_path() {
  winpath="$1"
  case "$winpath" in
    [A-Za-z]:\\*|[A-Za-z]:/*)
      drive=$(printf '%s' "$winpath" | cut -d: -f1 | tr 'A-Z' 'a-z')
      restpath=$(printf '%s' "$winpath" | cut -d: -f2-)
      if [ "$drive" = "z" ]; then
        printf '%s' "$restpath"
      elif [ "$drive" = "c" ]; then
        printf '%s/drive_c%s' "$WINEPREFIX" "$restpath"
      else
        dosdev="$WINEPREFIX/dosdevices/${drive}:"
        if [ -L "$dosdev" ]; then
          target=$(readlink "$dosdev")
          printf '%s%s' "$target" "$restpath"
        else
          printf '%s/drive_%s%s' "$WINEPREFIX" "$drive" "$restpath"
        fi
      fi
      ;;
    *)
      printf '%s' "$winpath"
      ;;
  esac
}

# Decode Unicode escapes, normalize backslashes, shorten home
cleanpath() {
  result="$1"
  result=$(printf '%s' "$result" | awk '
    {
      while (match($0, /\\[0-9a-fA-F]{4}/)) {
        hex = substr($0, RSTART + 1, RLENGTH - 1)
        c = strtonum("0x" hex)
        $0 = substr($0, 1, RSTART - 1) sprintf("%c", c) substr($0, RSTART + RLENGTH)
      }
      print
    }' 2>/dev/null)
  result=$(printf '%s' "$result" | sed 's|\\|/|g' | sed 's|///*|/|g')
  printf '%s' "$result" | sed "s|^$HOME|~|"
}

# Suppress Wine mono/gecko install dialogs during prefix creation only.
# mscoree=d and mshtml=d disable .NET/HTML loading for wineboot, preventing
# the dialog. This override is NOT exported — trace runs can use native .NET
# if installed. The dialog only appears during wineboot, not during app runs.

# Detect xvfb-run for headless/CI tracing (like quick-sharun.sh)
if command -v xvfb-run >/dev/null 2>&1; then
  XVFB_CMD="xvfb-run -a --"
else
  XVFB_CMD=""
  _err_msg "WARNING: xvfb-run was not detected, GUI apps may not run without a display"
fi

# If arg is an executable, find all exes and trace each one
# Detect PE by extension or by MZ magic header
_is_pe() {
  case "$1" in
    *.exe|*.EXE) return 0 ;;
  esac
  [ -f "$1" ] || return 1
  head -c 2 "$1" 2>/dev/null | grep -qa 'MZ'
}

if [ -d "$1" ]; then
    # Directory: trace all .exe files inside it
    app_dir="$1"
    exe_path=""
    all_exes=$(find "$app_dir" -type f \( -name '*.exe' -o -name '*.EXE' \) 2>/dev/null | sort -u)

    if [ -n "$WINE_STRACE_BINARY" ]; then
      filtered=""
      for exe in $all_exes; do
        base=$(basename "$exe")
        for name in $WINE_STRACE_BINARY; do
          [ "$base" = "$name" ] && { filtered="$filtered $exe"; break; }
        done
      done
      all_exes=$filtered
    fi

    if [ -z "$all_exes" ]; then
      _err_msg "ERROR: No .exe files found in $app_dir"
      exit 1
    fi

    _echo "* Found executables in $app_dir:"
    for exe in $all_exes; do
      _echo " - $exe"
    done

elif _is_pe "$1"; then
    exe_path="$1"
    app_dir=$(dirname "$exe_path")

    # If arg has .exe extension, search the directory tree for all exes
    # If arg is a PE without extension, trace only that single file
    case "$exe_path" in
      *.exe|*.EXE)
        all_exes=$(find "$app_dir" -type f \( -name '*.exe' -o -name '*.EXE' \) 2>/dev/null | sort -u)
        ;;
      *)
        all_exes="$exe_path"
        ;;
    esac

    # Filter by WINE_STRACE_BINARY if set
    if [ -n "$WINE_STRACE_BINARY" ]; then
      filtered=""
      for exe in $all_exes; do
        base=$(basename "$exe")
        for name in $WINE_STRACE_BINARY; do
          [ "$base" = "$name" ] && { filtered="$filtered $exe"; break; }
        done
      done
      all_exes=$filtered
    fi

    if [ -z "$all_exes" ]; then
      _err_msg "ERROR: No .exe files found in $app_dir"
      exit 1
    fi

else
    trace="$1"
    [ -f "$trace" ] || { _err_msg "ERROR: File not found: $trace"; exit 1; }
fi

if [ -n "$all_exes" ]; then
    _echo "* Removing existing prefix..."
    wineserver -k 2>/dev/null
    rm -rf "$WINEPREFIX"
    mkdir -p "$WINEPREFIX"
    _echo "* Creating fresh prefix..."
    if [ -n "$XVFB_CMD" ]; then
      $XVFB_CMD env WINEDLLOVERRIDES="mscoree=d;mshtml=d" wine wineboot -u 2>/dev/null
    else
      WINEDLLOVERRIDES="mscoree=d;mshtml=d" wine wineboot -u 2>/dev/null
    fi
    [ -d "$WINEPREFIX/drive_c/windows" ] || { _err_msg "ERROR: Failed to create Wine prefix at $WINEPREFIX (wineboot failed)"; exit 1; }
    trace=$(mktemp /tmp/wine-trace-XXXXXX.txt)

    for exe in $all_exes; do
      _echo "STRACE: [$exe] ..."
      set -m
      if [ -n "$XVFB_CMD" ]; then
        $XVFB_CMD env WINEDEBUG=+loaddll wine "$exe" $WINE_STRACE_FLAGS >> "$trace" 2>&1 &
      else
        WINEDEBUG=+loaddll wine "$exe" $WINE_STRACE_FLAGS >> "$trace" 2>&1 &
      fi
      pid=$!
      set +m

      sleep "$WINE_STRACE_TIME"
      kill -TERM -$pid 2>/dev/null || :
      sleep 1
      kill -KILL -$pid 2>/dev/null || :
      wait "$pid" 2>/dev/null || :
      wineserver -k 2>/dev/null || wine wineserver -k 2>/dev/null || :
    done
    pid=1  # flag that we created a temp trace
fi

cd "$WINEPREFIX/drive_c/windows" || exit 1

_echo "Collecting loaded modules..."
win_paths=$(mktemp)
grep -E 'build_module|build_ntdll_module' "$trace" |
  sed -n 's/.*L"\([^"]*\)".*/\1/p' |
  tr 'A-Z' 'a-z' |
  sort -u > "$win_paths"
loaded=""
while IFS= read -r winpath; do
  [ -z "$winpath" ] && continue
  linuxpath=$(cleanpath "$(map_path "$winpath")")
  _echo "  $linuxpath"
  loaded="$loaded $(printf '%s' "$linuxpath" | sed 's|.*/||')"
done < "$win_paths"
rm -f "$win_paths"
loaded=$(printf '%s' "$loaded" | tr ' ' '\n' | sort -u | sed '/^$/d')

# --- Extract direct imports via objdump + delay-load imports via POSIX PE parser ---
# Delay-load imports are stored in PE's Delay Import Directory and are not
# shown by objdump. They are loaded on demand, so a short runtime trace may
# miss them (e.g. mpr.dll for network paths in file dialogs).
# Parsed using only dd, od, and shell arithmetic (no Python, no winedump).
# Each exe in the app directory is analyzed.
objdump_imports=""
delay_imports=""
if [ -n "$all_exes" ]; then
  # POSIX PE parser helper: extract delay-load DLL names from a PE file
  # Outputs lowercased DLL names, one per line
  pe_delay_imports() {
    pe_file="$1"
    read_le32() {
      dd if="$1" bs=1 skip="$2" count=4 2>/dev/null | od -An -tu4 | tr -d ' \n'
    }
    read_le16() {
      dd if="$1" bs=1 skip="$2" count=2 2>/dev/null | od -An -tu2 | tr -d ' \n'
    }
    read_str() {
      dd if="$1" bs=1 skip="$2" count=256 2>/dev/null | tr '\0' '\n' | head -n 1
    }

    hdr_tmp=$(mktemp)
    dd if="$pe_file" bs=8192 count=1 of="$hdr_tmp" 2>/dev/null

    pe_off=$(read_le32 "$hdr_tmp" 60)
    [ -z "$pe_off" ] && { rm -f "$hdr_tmp"; return; }

    sig=$(read_le32 "$hdr_tmp" "$pe_off")
    [ "$sig" != "17744" ] && { rm -f "$hdr_tmp"; return; }

    num_sections=$(read_le16 "$hdr_tmp" $((pe_off + 6)))
    opt_hdr_size=$(read_le16 "$hdr_tmp" $((pe_off + 20)))
    magic=$(read_le16 "$hdr_tmp" $((pe_off + 24)))

    if [ "$magic" = "523" ]; then
      dd_base=$((pe_off + 24 + 112))
      img_base=0
    elif [ "$magic" = "267" ]; then
      dd_base=$((pe_off + 24 + 96))
      img_base=$(read_le32 "$hdr_tmp" $((pe_off + 24 + 28)))
    else
      rm -f "$hdr_tmp"; return
    fi

    delay_rva=$(read_le32 "$hdr_tmp" $((dd_base + 13 * 8)))
    delay_size=$(read_le32 "$hdr_tmp" $((dd_base + 13 * 8 + 4)))
    [ "$delay_size" = "0" ] && { rm -f "$hdr_tmp"; return; }

    sec_table=$((pe_off + 24 + opt_hdr_size))

    rva_to_off() {
      rva=$1
      i=0
      while [ "$i" -lt "$num_sections" ]; do
        sec=$((sec_table + i * 40))
        va=$(read_le32 "$hdr_tmp" $((sec + 12)))
        raw_sz=$(read_le32 "$hdr_tmp" $((sec + 16)))
        raw_ptr=$(read_le32 "$hdr_tmp" $((sec + 20)))
        if [ "$rva" -ge "$va" ] 2>/dev/null && \
           [ "$rva" -lt $((va + raw_sz)) ] 2>/dev/null; then
          echo $((raw_ptr + rva - va))
          return
        fi
        i=$((i + 1))
      done
    }

    dir_off=$(rva_to_off "$delay_rva")
    [ -z "$dir_off" ] && { rm -f "$hdr_tmp"; return; }

    idx=0
    while true; do
      entry=$((dir_off + idx * 32))
      dll_name_rva=$(read_le32 "$pe_file" $((entry + 4)))
      [ "$dll_name_rva" = "0" ] && break
      if [ "$img_base" -gt 0 ] 2>/dev/null && \
         [ "$dll_name_rva" -ge "$img_base" ] 2>/dev/null; then
        dll_name_rva=$((dll_name_rva - img_base))
      fi
      name_off=$(rva_to_off "$dll_name_rva")
      if [ -n "$name_off" ]; then
        read_str "$pe_file" "$name_off" | tr 'A-Z' 'a-z'
      fi
      idx=$((idx + 1))
    done
    rm -f "$hdr_tmp"
  }

  # Track what's already been shown to avoid duplicates across exes
  shown="$loaded"

  for exe in $all_exes; do
    exe_base=$(basename "$exe")

    if command -v objdump >/dev/null 2>&1; then
      imports=$(LC_ALL=C objdump -x "$exe" 2>/dev/null |
        grep "DLL Name:" | sed 's/.*DLL Name: //' | tr 'A-Z' 'a-z' | sort -u)
      # Only show imports not already in loaded or shown by a previous exe
      new_imports=""
      for m in $imports; do
        printf '%s\n' "$shown" | grep -Fxq "$m" 2>/dev/null || new_imports="$new_imports $m"
      done
      if [ -n "$new_imports" ]; then
        _echo "Collecting direct imports: [$exe_base]"
        for m in $new_imports; do
          _echo "  $m"
          shown="$shown
$m"
        done
      fi
      objdump_imports=$(printf '%s\n%s' "$objdump_imports" "$imports")
    fi

    delays=$(pe_delay_imports "$exe")
    if [ -n "$delays" ]; then
      # Only show delay-loads not already in loaded or shown by a previous exe
      new_delays=""
      for m in $delays; do
        printf '%s\n' "$shown" | grep -Fxq "$m" 2>/dev/null || new_delays="$new_delays $m"
      done
      if [ -n "$new_delays" ]; then
        _echo "Collecting delay-load imports: [$exe_base]"
        # Determine exe bitness for system dir lookup
        pe_off=$(dd if="$exe" bs=1 skip=60 count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
        magic=$(dd if="$exe" bs=1 skip=$((pe_off + 24)) count=2 2>/dev/null | od -An -tu2 | tr -d ' \n')
        [ "$magic" = "523" ] && sysdir=system32 || sysdir=syswow64
        exe_dir="${exe%/*}"
        for m in $new_delays; do
          if [ -f "$exe_dir/$m" ]; then
            _echo "  $(cleanpath "$exe_dir/$m")"
          elif [ -f "$WINEPREFIX/drive_c/windows/$sysdir/$m" ]; then
            _echo "  $(cleanpath "$WINEPREFIX/drive_c/windows/$sysdir/$m")"
          else
            _echo "  $m (not found)"
          fi
          shown="$shown
$m"
        done
      fi
      delay_imports=$(printf '%s\n%s' "$delay_imports" "$delays")
    fi
  done
  objdump_imports=$(printf '%s' "$objdump_imports" | sort -u | sed '/^$/d')
  delay_imports=$(printf '%s' "$delay_imports" | sort -u | sed '/^$/d')
fi

# --- Whitelist: keep these even if not in trace ---
# mpr.dll and comdlg32.dll are kept here as a safety net, but delay-load
# detection above should catch them automatically for most apps.
# We keep winsxs dir and system.ini by never deleting them below.
always_dll="mpr.dll comdlg32.dll"
# Always keep WoW64 transition DLLs (64-bit only)
wow64="wow64.dll wow64cpu.dll wow64win.dll"

keep_dll=$(printf '%s\n%s\n%s\n%s\n%s' "$loaded" "$always_dll" "$wow64" "$objdump_imports" "$delay_imports" | grep '\.dll$' | sort -u)
always_exe="explorer.exe"
keep_exe=$(printf '%s\n%s' "$loaded" "$always_exe" | grep '\.exe$' | sort -u)
keep_sys=$(printf '%s' "$loaded" | grep '\.sys$' | sort -u)
keep_drv=$(printf '%s' "$loaded" | grep '\.drv$' | sort -u)
keep_all=$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$loaded" "$always_dll" "$wow64" "$always_exe" "$objdump_imports" "$delay_imports" | sort -u)

count_dll=0; count_exe=0; count_sys=0; count_drv=0

_echo "Cleaning prefix..."

# --- Clean system32 ---
for f in system32/*.dll system32/*.drv; do
  [ -f "$f" ] || continue
  base=$(basename "$f" | tr 'A-Z' 'a-z')
  found=0
  for k in $keep_dll $keep_drv; do [ "$base" = "$k" ] && { found=1; break; }; done
  [ "$found" = 0 ] && rm -f "$f" || { count_dll=$((count_dll+1)); }
done

for f in system32/*.exe; do
  [ -f "$f" ] || continue
  base=$(basename "$f" | tr 'A-Z' 'a-z')
  found=0
  for k in $keep_exe; do [ "$base" = "$k" ] && { found=1; break; }; done
  [ "$found" = 0 ] && rm -f "$f" || { count_exe=$((count_exe+1)); }
done

for f in system32/drivers/*.sys; do
  [ -f "$f" ] || continue
  base=$(basename "$f" | tr 'A-Z' 'a-z')
  found=0
  for k in $keep_sys; do [ "$base" = "$k" ] && { found=1; break; }; done
  [ "$found" = 0 ] && rm -f "$f" || { count_sys=$((count_sys+1)); }
done

# --- Clean syswow64 ---
for f in syswow64/*.dll; do
  [ -f "$f" ] || continue
  base=$(basename "$f" | tr 'A-Z' 'a-z')
  found=0
  for k in $keep_dll; do [ "$base" = "$k" ] && { found=1; break; }; done
  [ "$found" = 0 ] && rm -f "$f" || { count_dll=$((count_dll+1)); }
done

for f in syswow64/*.exe; do
  [ -f "$f" ] || continue
  base=$(basename "$f" | tr 'A-Z' 'a-z')
  found=0
  for k in $keep_exe; do [ "$base" = "$k" ] && { found=1; break; }; done
  [ "$found" = 0 ] && rm -f "$f" || { count_exe=$((count_exe+1)); }
done

# --- Remove unused data directories (winsxs and system.ini preserved) ---
rm -rf Fonts help inf logs performance resources security system tasks temp
rm -rf command globalization twain_32 twain_64 2>/dev/null

_echo "------------------------------------------------------------"
_echo "* Kept: $count_dll DLLs, $count_exe EXEs, $count_sys SYS, $count_drv DRV"
_echo "* Prefix: $(du -sh . | cut -f1)"
_echo "* Files: $(find . -type f | wc -l)"
_echo "------------------------------------------------------------"

[ -n "$pid" ] && rm -f "$trace"

# --- Clean system Wine builtins in /usr/lib/wine/ ---

# PE-like files in -windows/ dirs (ELF shared objects named .dll/.exe/etc.)
for sysdir in /usr/lib/wine/i386-windows /usr/lib/wine/x86_64-windows; do
  [ -d "$sysdir" ] || continue
  [ ! -w "$sysdir" ] && s=sudo || s=
  _echo "Cleaning: $sysdir"

  count=0; size=0
  for f in "$sysdir"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f" | tr 'A-Z' 'a-z')
    case "${base##*.}" in
      dll|exe|drv|sys|cpl|ocx|acm|ax|dll16|drv16|exe16|vxd|mod16|com) ;;
      *) continue ;;
    esac
    found=0
    for k in $keep_all; do [ "$base" = "$k" ] && { found=1; break; }; done
    if [ "$found" = 0 ]; then
      sz=$($s stat -c%s "$f" 2>/dev/null || echo 0)
      $s rm -f "$f"
      size=$((size + sz))
      count=$((count + 1))
    fi
  done
  [ "$count" -gt 0 ] && _echo "  Removed $count files ($size bytes)"
done

# Unix-side .so builtins in -unix/ dirs
# Map .so name to PE module name by trying .dll, .drv, .sys extensions
# .so files with no PE counterpart are internal backends loaded through
# the unixlib interface, invisible to +loaddll traces — always kept
internal_keep="gphoto2.so sane.so winealsa.so winepulse.so"
for unixdir in /usr/lib/wine/x86_64-unix /usr/lib/wine/i386-unix; do
  [ -d "$unixdir" ] || continue
  [ ! -w "$unixdir" ] && s=sudo || s=
  _echo "Cleaning: $unixdir"

  count=0; size=0
  for f in "$unixdir"/*.so; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    name="${base%.so}"

    # Always keep Wine-internal modules
    found=0
    for k in $internal_keep; do [ "$base" = "$k" ] && { found=1; break; }; done
    [ "$found" = 1 ] && continue

    # Check PE module mapping: try .dll, .drv, .sys
    for ext in dll drv sys; do
      pe="${name}.${ext}"
      for k in $keep_all; do
        [ "$pe" = "$k" ] && { found=1; break; }
      done
      [ "$found" = 1 ] && break
    done

    if [ "$found" = 0 ]; then
      sz=$($s stat -c%s "$f" 2>/dev/null || echo 0)
      $s rm -f "$f"
      size=$((size + sz))
      count=$((count + 1))
    fi
  done
  [ "$count" -gt 0 ] && _echo "  Removed $count files ($size bytes)"
done
