echo "Sourcing configure-go-hook"

goConfigurePhase() {
  echo "Executing goConfigurePhase"
  runHook preConfigure

  # No configure phase behaviour provided at the moment.
  # This hook mainly exists to opt out of the default nixpkgs
  # configurePhase behaviour.

  # Go commands needs a working home directory
  if [ -z "${HOME}" ] || [ "${HOME}" = "/homeless-shelter" ] ; then
    export HOME=$TMPDIR
  fi

  # The sandbox directory is part of a package's cache key unless trimmed.
  # On Linux it is always /build, but on Darwin every build gets its own
  # directory, so without this no build hits the cache of its inputs.
  export GOFLAGS="-trimpath${GOFLAGS:+ $GOFLAGS}"

  # cgo is part of a package's cache key too (it selects files of net, os/user,
  # runtime/cgo...): std, modules and apps must agree. Static by default.
  export CGO_ENABLED="${CGO_ENABLED:-0}"

  runHook postConfigure
  echo "Finished executing goConfigurePhase"
}

if [ -z "${dontUseGoConfigure-}" ] && [ -z "${configurePhase-}" ]; then
  echo "Using goConfigurePhase"
  configurePhase=goConfigurePhase
fi
