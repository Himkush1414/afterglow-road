#!/usr/bin/env bash
# Installs the pinned toolchain under _local/tools/ (never outside the
# project). Every download is checked against a pinned checksum before it
# is unpacked; a second run only verifies and changes nothing.
#
#   tools/setup_toolchain.sh [all|godot|templates|jdk|android|blender|python]
#
# Writes _local/tools/TOOLCHAIN.lock with what was installed. Runs with the
# GitHub token variables removed and HOME pointed into _local/tools/_home,
# so no installer can read a credential store.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools="${root}/_local/tools"
cache="${tools}/_cache/downloads"
mkdir -p "${cache}" "${tools}/_home"
unset GH_TOKEN GITHUB_TOKEN
export HOME="${tools}/_home" XDG_CONFIG_HOME="${tools}/_home/.config" XDG_CACHE_HOME="${tools}/_home/.cache"
export PIP_CACHE_DIR="${tools}/_cache/pip"

# ---- pins (change only at a phase boundary; record the change in the plan)
GODOT_VERSION=4.7.2-stable
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}"
GODOT_EDITOR_ZIP="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
GODOT_TEMPLATES_TPZ="Godot_v${GODOT_VERSION}_export_templates.tpz"
JDK_VERSION=17.0.21+9
JDK_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz"
JDK_SHA256=8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711
ANDROID_CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip"
ANDROID_CMDLINE_SHA1=040d3996a65543d22ec4bf73e4c37aa37a8d4af4
ANDROID_PACKAGES=("platform-tools" "platforms;android-35" "platforms;android-36" "build-tools;35.0.1"
	"ndk;28.1.13356709" "cmake;3.10.2.4988404")
BLENDER_VERSION=5.2.4
BLENDER_URL="https://download.blender.org/release/Blender5.2/blender-${BLENDER_VERSION}-linux-x64.tar.xz"
BLENDER_SHA256=2fd14c50987426897ba60237ee996edf2b4151f4b1a72a460ca20be58c1d2d86

say() { printf 'toolchain: %s\n' "$*"; }
die() { printf 'toolchain: ERROR: %s\n' "$*" >&2; exit 1; }

fetch() { # url file algo sum
	local url="$1" out="${cache}/$2" algo="$3" sum="$4"
	if [[ ! -f "${out}" ]] || ! printf '%s  %s\n' "${sum}" "${out}" | "${algo}sum" -c --status; then
		say "downloading $2"
		curl -fL --retry 3 --max-time 3600 -o "${out}.part" "${url}"
		mv "${out}.part" "${out}"
	fi
	printf '%s  %s\n' "${sum}" "${out}" | "${algo}sum" -c --status || { rm -f "${out}"; die "checksum mismatch for $2"; }
}

godot_sum() { # file -> sha512 from the release's own list, itself kept in the repo-local download folder
	local list="${tools}/godot/${GODOT_VERSION}/downloads/SHA512-SUMS.txt"
	[[ -f "${list}" ]] || { mkdir -p "$(dirname "${list}")"; curl -fsSL --retry 3 -o "${list}" "${GODOT_URL}/SHA512-SUMS.txt"; }
	awk -v f="$1" '$2 == f {print $1}' "${list}"
}

install_godot() {
	local dir="${tools}/godot/${GODOT_VERSION}" bin
	bin="${dir}/Godot_v${GODOT_VERSION}_linux.x86_64"
	if [[ ! -x "${bin}" ]]; then
		fetch "${GODOT_URL}/${GODOT_EDITOR_ZIP}" "${GODOT_EDITOR_ZIP}" sha512 "$(godot_sum "${GODOT_EDITOR_ZIP}")"
		mkdir -p "${dir}" && unzip -q -o "${cache}/${GODOT_EDITOR_ZIP}" -d "${dir}"
	fi
	touch "${dir}/_sc_"   # self-contained mode: editor data stays beside the binary
	"${bin}" --version | head -1
}

install_templates() {
	local dir="${tools}/godot/${GODOT_VERSION}/editor_data/export_templates/${GODOT_VERSION/-/.}"
	if [[ ! -f "${dir}/version.txt" ]]; then
		fetch "${GODOT_URL}/${GODOT_TEMPLATES_TPZ}" "${GODOT_TEMPLATES_TPZ}" sha512 "$(godot_sum "${GODOT_TEMPLATES_TPZ}")"
		local tmp="${cache}/templates.unpack"
		rm -rf "${tmp}" && mkdir -p "${tmp}" "${dir}"
		unzip -q "${cache}/${GODOT_TEMPLATES_TPZ}" -d "${tmp}"
		cp -a "${tmp}/templates/." "${dir}/" && rm -rf "${tmp}"
	fi
	printf 'export templates %s\n' "$(cat "${dir}/version.txt")"
}

install_jdk() {
	local dir="${tools}/android/jdk"
	if [[ ! -x "${dir}/bin/java" ]]; then
		fetch "${JDK_URL}" "jdk-${JDK_VERSION}.tar.gz" sha256 "${JDK_SHA256}"
		rm -rf "${dir}" && mkdir -p "${dir}"
		tar -xzf "${cache}/jdk-${JDK_VERSION}.tar.gz" -C "${dir}" --strip-components=1
	fi
	"${dir}/bin/java" -version 2>&1 | head -1
}

install_android() {
	install_jdk >/dev/null
	local sdk="${tools}/android/sdk" mgr
	mgr="${sdk}/cmdline-tools/latest/bin/sdkmanager"
	if [[ ! -x "${mgr}" ]]; then
		fetch "${ANDROID_CMDLINE_URL}" cmdline-tools.zip sha1 "${ANDROID_CMDLINE_SHA1}"
		local tmp="${cache}/cmdline.unpack"
		rm -rf "${tmp}" && mkdir -p "${tmp}" "${sdk}/cmdline-tools"
		unzip -q "${cache}/cmdline-tools.zip" -d "${tmp}"
		rm -rf "${sdk}/cmdline-tools/latest" && mv "${tmp}/cmdline-tools" "${sdk}/cmdline-tools/latest" && rm -rf "${tmp}"
	fi
	export JAVA_HOME="${tools}/android/jdk" ANDROID_HOME="${sdk}" ANDROID_SDK_ROOT="${sdk}"
	# sdkmanager checks every package against the checksum in Google's repository index.
	yes | "${mgr}" --sdk_root="${sdk}" --licenses >/dev/null 2>&1 || true
	local missing=()
	for p in "${ANDROID_PACKAGES[@]}"; do
		[[ -d "${sdk}/${p//;//}" ]] || missing+=("${p}")
	done
	if ((${#missing[@]})); then
		say "installing ${missing[*]}"
		"${mgr}" --sdk_root="${sdk}" --install "${missing[@]}" >/dev/null
	fi
	"${mgr}" --sdk_root="${sdk}" --list_installed 2>/dev/null | awk -F'|' 'NR>3 && NF>2 {gsub(/ /,"",$1); gsub(/ /,"",$2); print $1" "$2}'
}

install_blender() {
	local dir="${tools}/blender/${BLENDER_VERSION}"
	if [[ ! -x "${dir}/blender" ]]; then
		fetch "${BLENDER_URL}" "blender-${BLENDER_VERSION}.tar.xz" sha256 "${BLENDER_SHA256}"
		rm -rf "${dir}" && mkdir -p "${dir}"
		tar -xJf "${cache}/blender-${BLENDER_VERSION}.tar.xz" -C "${dir}" --strip-components=1
	fi
	"${dir}/blender" --version 2>/dev/null | head -1
}

install_python() {
	local venv="${tools}/venv"
	[[ -x "${venv}/bin/python" ]] || python3 -m venv "${venv}"
	"${venv}/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes -r "${root}/tools/requirements.txt"
	printf 'python %s; ' "$("${venv}/bin/python" -c 'import sys; print(sys.version.split()[0])')"
	"${venv}/bin/python" -c 'import numpy, PIL; print("numpy", numpy.__version__, "pillow", PIL.__version__, end="; ")'
	"${venv}/bin/gdlint" --version
}

target="${1:-all}"
lock="${tools}/TOOLCHAIN.lock"
declare -A out=()
for part in godot templates jdk android blender python; do
	[[ "${target}" == all || "${target}" == "${part}" ]] || continue
	out[${part}]="$("install_${part}")"
	say "${part}: ok"
done
if [[ "${target}" == all ]]; then
	{
		printf '# Written by tools/setup_toolchain.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		for part in godot templates jdk android blender python; do
			printf '[%s]\n%s\n\n' "${part}" "${out[${part}]}"
		done
	} >"${lock}"
	say "lock written: ${lock#"${root}"/}"
fi
