# Sourced by build.sh (macOS) and build-linux.sh: the sources both build
# from, pinned by sha256, and how they're downloaded into $cache_dir. The
# caller defines log and die.

# QEMU 11.1.1 (the commit Try Omarchy builds), and the submodules the
# gitlab archive leaves out.
qemu_version=11.1.1
qemu_commit=c3d48b7d1e89604920e5b81b91140c2ad39a1943
keycodemap_commit=f5772a62ec52591ff6870b7e8ef32482371f22c6
dtc_commit=b6910bec11614980a21e46fbccc35934b671bd81

virgl_version=1.3.0

# SPICE's protocol headers (header-only): QEMU's qemu-vdagent needs them.
spice_protocol_version=0.14.5

# Build tools: meson and PyYAML (virglrenderer's generated tables), and the
# wheels QEMU's offline venv needs.
meson_version=1.9.0
pyyaml_version=6.0.3

# name  url  sha256  (the file is saved as the url's last component)
common_sources() {
  cat <<EOF
qemu-$qemu_commit.tar.gz	https://gitlab.com/qemu-project/qemu/-/archive/$qemu_commit/qemu-$qemu_commit.tar.gz	7563781d7dec46f11509801e027f852597235d29ca7afa44a07ed9d8b108b8cd
keycodemapdb-$keycodemap_commit.tar.gz	https://gitlab.com/qemu-project/keycodemapdb/-/archive/$keycodemap_commit/keycodemapdb-$keycodemap_commit.tar.gz	d014b53382dbb17b8196ad12f50de7f20d0ef1b9f7d54b0be51a6cbb14209195
dtc-$dtc_commit.tar.gz	https://git.kernel.org/pub/scm/utils/dtc/dtc.git/snapshot/dtc-$dtc_commit.tar.gz	e115f987eec23a1ba25150a46ced1675de3716072d3b4905afb3a9cda0f007c7
virglrenderer-$virgl_version.tar.gz	https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/$virgl_version/virglrenderer-$virgl_version.tar.gz	065bc56e89e6f631f96101cd62eba0748e48eb888b434edc86e89d05395e76f3
spice-protocol-$spice_protocol_version.tar.xz	https://www.spice-space.org/download/releases/spice-protocol-$spice_protocol_version.tar.xz	baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7
meson-$meson_version.tar.gz	https://github.com/mesonbuild/meson/releases/download/$meson_version/meson-$meson_version.tar.gz	cd27277649b5ed50d19875031de516e270b22e890d9db65ed9af57d18ebc498d
pyyaml-$pyyaml_version.tar.gz	https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-$pyyaml_version.tar.gz	d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f
setuptools-84.0.0-py3-none-any.whl	https://files.pythonhosted.org/packages/95/9c/c510029fc6ef33a6275cd2c5d3cecd6613dfd6aa401d57c54f1c18852ccf/setuptools-84.0.0-py3-none-any.whl	51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670
wheel-0.48.0-py3-none-any.whl	https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/wheel-0.48.0-py3-none-any.whl	3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab
packaging-26.3-py3-none-any.whl	https://files.pythonhosted.org/packages/63/34/ba1c580383c9eada3711951fef0795c80b829a078d72188184bcab9dd527/packaging-26.3-py3-none-any.whl	d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c
pip-26.2.1-py3-none-any.whl	https://files.pythonhosted.org/packages/f3/6e/1736e5b4ae2b778ef2f81c47d797de9f891d4d8acb047a24ca37a60294dd/pip-26.2.1-py3-none-any.whl	71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e
EOF
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch FILE SHA256 CURL-ARGS...: into the cache, unless it's there already.
fetch() {
  local file="$cache_dir/$1" sha=$2; shift 2
  if [[ -f "$file" && $(sha256 "$file") == "$sha" ]]; then return; fi
  log "Downloading $(basename "$file")"
  curl -fL --silent --show-error --proto '=https' --tlsv1.2 --retry 3 \
    --retry-all-errors --connect-timeout 20 -o "$file.part" "$@"
  [[ $(sha256 "$file.part") == "$sha" ]] || {
    rm -f "$file.part"; die "checksum mismatch for $(basename "$file")"; }
  mv "$file.part" "$file"
}

# The sources listed on stdin (name, url, sha256).
fetch_all() {
  local file url sha
  while IFS=$'\t' read -r file url sha; do
    fetch "$file" "$sha" "$url"
  done
}
