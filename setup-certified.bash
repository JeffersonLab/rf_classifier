#!/bin/bash

SCRIPT_NAME=$(basename $0)
PYTHON='/usr/csite/pubtools/bin/python3.7'

if [ ! -f './setup-certified.bash' ] ; then
    echo "This script must be run from it's local directory"
    exit 1
fi

SUPPORTED_OS='rhel-7-x86_64:devl77 rhel-9-x86_64:devl90'

usage () {
    echo "
To install in certified.

1. Build and test code.
> $0 test

2. Generate docs.  Then copy to certified web area.
> $0 docs

3. Install in certified.  Copies files, install dependencies in venv dir.
> mkdir -p /path/to/new/version
> $0 install /path/to/new/version

4. Clean up this local copy into a certified tarball.
> $0 compact

Usage:
  $0 [test|docs|install|compact]
  test
    Build app and run tests for all architectures.  Done the build directory
  docs
    Build and install docs in the ./docs directory
  install <install_dir>
    Creates architecture directories and installs architecture specific
    version in <install_dir>.  No clean step as we copy only what is needed.
  compact
    Remove everything that can be regenerated by 'test' and/or 'docs'
"
}

run_install () {
  install_dir="$1"
  if [ -z "$install_dir" -o ! -d "$install_dir" ] ; then
    echo "Install dir not found '$install_dir'"
    exit 1
  fi

  for os_host in $SUPPORTED_OS
  do
    read os host < <(echo $os_host | tr  ':' ' ')
    echo
    echo "### INSTALLING FOR $os VIA $host AT $install_dir"
    if [ ! -d $install_dir/$os ] ; then
      mkdir $install_dir/$os
      if [ "0" != "$?" ] ; then
          echo "Error making directory"
          exit 1
      fi
    fi
    rsync -a --exclude="build/" --exclude=docs  --exclude=tests --exclude=docsrc --exclude="venv/" ./ $install_dir/$os/
    opwd=$(pwd)
    ssh $host "cd $opwd/$install_dir/$os && ./$SCRIPT_NAME install_local"
  done
}

run_install_local () {
    install_type="$1"

    if [ ! -d ./venv ] ; then
        echo -n "Making venv, "
        $PYTHON -m venv ./venv
    fi

    # Activate virtual environment, install installation dependencies, install requirements
    source ./venv/bin/activate
    echo -n 'Installing build tools, '
    pip3 install -qq pip==23.0 setuptools==67.1.0
    if [ "0" != "$?" ] ; then
        echo "Error updating installation dependencies"
        exit 1
    fi
    echo -n 'dependencies, '
    pip3 install -qq -r requirements.txt
    if [ "0" != "$?" ] ; then
        echo "Error installing application dependencies"
        exit 1
    fi

    # Install this application in editable mode so the source code itself is referenced
    echo -n 'source code '
    if [ "$install_type" == 'dev' ] ; then
      pip3 install -qq -e .[dev]
    else
      pip3 install -qq -e .
    fi
    if [ "0" != "$?" ] ; then
        echo "Error installing application"
        exit 1
    fi
    deactivate

    echo "and deleting unneeded files"
    if [ "$install_type" != 'dev' ] ; then
      rm -rf test/ docsrc/ docs/ build/
      rm -f README.md requirements.txt setup.cfg setup.py setup-certified.bash
    fi
}

docs () {
  echo "Installing locally"
  run_install_local dev

  echo "Generating docs"
  if [ ! -d docs ] ; then
    mkdir docs
  fi
  source venv/bin/activate
  opwd=$(pwd)
  cd docsrc
  make github
  cd $opwd
  deactivate
}

run_tests () {
  if [ !  -d './build' ] ; then
    mkdir build
    if [ "0" != "$?" ] ; then
      echo "Error creating build dir"
      exit 1
    fi
  fi

  opwd=$(pwd)
  install_dir="./build"
  run_install "$install_dir"

  for os_host in $SUPPORTED_OS
  do
    read os host < <(echo $os_host | tr  ':' ' ')
    test_dir="$opwd/build/$os"

    echo
    echo "### TESTING FOR $os VIA $host AT $test_dir ###"

    cp ./$SCRIPT_NAME $test_dir
    cp -r ./tests $test_dir

    ssh $host "cd $test_dir&& ./$SCRIPT_NAME test_local"
  done
}

run_tests_local () {
    source ./venv/bin/activate
    python3 -m unittest
    deactivate
    if [ -d test/test-data/tmp ] ; then
        rm -rf test/test-data/tmp
    fi
}

compact_local () {
    echo "Compacting - removing everything that can be remade by docs and test targets"
    rm -rf venv/
    rm -rf docs/*
    rm -rf docsrc/build/*
    rm -rf build/
    rm -rf .eggs/
    rm -rf rf_classifier.egg-info
    rm -rf src/rf_classifier.egg-info
    find src/ -type d -name __pycache__ -delete -o -type f -name '*.py[co]' -delete
    find tests/ -type d -name __pycache__ -delete -o -type f -name '*.py[co]' -delete
    find ./ -type d -name "rf_classifier.egg-info" -delete
    rm -rf UNKNOWN.egg-info
}

make_certified_tarball () {
  tar_name="$1"

  if [ -z "$tar_name" ] ; then
    echo "Requires one argument.  Name of tarball (without .tar.gz)"
    exit 1
  fi

  if [ -d ../$tar_name ] ; then
    echo "Target directory already exists - '../$tar_name'"
    exit 1
  fi

  echo "Compacting local directory"
  compact_local

  echo "Copying local directory to $tar_name"
  rsync -aq --exclude=".git/" --exclude=".idea/" --exclude=".vscode/" --exclude='venv/' --exclude=".git*" ./* "../$tar_name/"
  if [ "0" != "$?" ] ; then
    echo "Error copying to ../$tar_name"
    exit 1
  fi

  echo "Creating tarball '../${tar_name}.tar.gz'"
  tar -czf ../${tar_name}.tar.gz ../${tar_name}/
  if [ "0" != "$?" ] ; then
    echo "Error creating tarball ../$tar_name"
    exit 1
  fi

  echo "Removing temp tarball source directory - '../${tar_name}'"
  rm -rf ../${tar_name}/
}

if [ $# -lt 1 ] ; then
    echo "Requires at least one argument.  Received $#"
    usage
    exit 1
fi

if [ ! -f "./$SCRIPT_NAME" ] ; then
    echo "Error: this script must be executed from within the base directory of the application."
    exit
fi

case $1 in
        "install") run_install $2; exit 0;;
  "install_local") run_install_local; exit 0;;
           "docs") docs; exit 0;;
           "test") run_tests; exit 0;;
        "tarball") make_certified_tarball "$2"; exit 0;;
     "test_local") run_tests_local; exit 0;;
        "compact") compact_local; exit 0;;
                *) echo "Unknown command: $1"; usage; exit 1;;
esac
