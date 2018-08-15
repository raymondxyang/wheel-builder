#!/usr/bin/env bash

set -ex

export ONNX_ML=1
WHEELHOUSE_DIR="wheelhouse"

# Build for given Python versions, or for all in /opt/python if none given
if [[ -z "$DESIRED_PYTHON" ]]; then
  DESIRED_PYTHON=($(ls -d /opt/python/*/))
fi
for (( i=0; i<"${#DESIRED_PYTHON[@]}"; i++ )); do
  # Convert eg. cp27-cp27m to /opt/python/cp27-cp27m
  if [[ ! -d "${DESIRED_PYTHON[$i]}" ]]; then
    if [[ -d "/opt/python/${DESIRED_PYTHON[$i]}" ]]; then
      DESIRED_PYTHON[$i]="/opt/python/${DESIRED_PYTHON[$i]}"
    else
      echo "Error: Given Python ${DESIRED_PYTHON[$i]} is not in /opt/python"
      echo "All array elements of env variable DESIRED_PYTHON must be"
      echo "valid Python installations under /opt/python"
      exit 1
    fi
  fi
done
unset 'DESIRED_PYTHON[${#DESIRED_PYTHON[@]}-1]'
echo "Will build for all Pythons: ${DESIRED_PYTHON[@]}"

ONNX_DIR="/onnx"
ONNX_BUILD_VERSION="1.2.2"
if [[ ! -d "ONNX_DIR" ]]; then
  git clone https://github.com/onnx/onnx $ONNX_DIR
  pushd $ONNX_DIR
  if ! git checkout v${ONNX_BUILD_VERSION}; then
      git checkout tags/v${ONNX_BUILD_VERSION}
  fi
else
  # the pyonnx dir will already be cloned and checked-out on jenkins jobs
  pushd $ONNX_DIR
fi
git submodule update --init --recursive

OLD_PATH=$PATH
for PYDIR in "${DESIRED_PYTHON[@]}"; do
    export PATH=$PYDIR/bin:$OLD_PATH
    python setup.py clean
    if [[ $PYDIR  == "/opt/python/cp37-cp37m" ]]; then
	break
    else
	pip install numpy==1.11
    fi
    time pip wheel --wheel-dir=$WHEELHOUSE_DIR .
done

popd

#######################################################################
# ADD DEPENDENCIES INTO THE WHEEL
#
# auditwheel repair doesn't work correctly and is buggy
# so manually do the work of copying dependency libs and patchelfing
# and fixing RECORDS entries correctly
######################################################################
yum install -y zip openssl

fname_with_sha256() {
    HASH=$(sha256sum $1 | cut -c1-8)
    DIRNAME=$(dirname $1)
    BASENAME=$(basename $1)
	INITNAME=$(echo $BASENAME | cut -f1 -d".")
	ENDNAME=$(echo $BASENAME | cut -f 2- -d".")
	echo "$DIRNAME/$INITNAME-$HASH.$ENDNAME"
}

make_wheel_record() {
    FPATH=$1
    if echo $FPATH | grep RECORD >/dev/null 2>&1; then
	# if the RECORD file, then
	echo "$FPATH,,"
    else
	HASH=$(openssl dgst -sha256 -binary $FPATH | openssl base64 | sed -e 's/+/-/g' | sed -e 's/\//_/g' | sed -e 's/=//g')
	FSIZE=$(ls -nl $FPATH | awk '{print $5}')
	echo "$FPATH,sha256=$HASH,$FSIZE"
    fi
}

rm -rf /$WHEELHOUS_DIR || true
rm -rf /tmp_dir || true
mkdir -p /$WHEELHOUSE_DIR
cp $ONNX_DIR/$WHEELHOUSE_DIR/*.whl /$WHEELHOUSE_DIR
mkdir /tmp_dir
pushd /tmp_dir

DEPS_LIST=(
    "/usr/local/lib/libprotobuf.so.9.0.1"
)
DEPS_SONAME=(
    "libprotobuf.so.9.0.1"
)


for whl in /$WHEELHOUSE_DIR/onnx*linux*.whl; do
    rm -rf tmp
    mkdir -p tmp
    cd tmp
    cp $whl .

    unzip -q $(basename $whl)
    rm -f $(basename $whl)

    # copy over needed dependent .so files over and tag them with their hash
    patched=()
    for filepath in "${DEPS_LIST[@]}"
    do
	filename=$(basename $filepath)
	destpath=onnx/.lib/$filename
	if [[ "$filepath" != "$destpath" ]]; then
	    mkdir -p $destpath
	    cp $filepath $destpath
	fi

	patchedpath=$(fname_with_sha256 $destpath)
	patchedname=$(basename $patchedpath)
	if [[ "$destpath" != "$patchedpath" ]]; then
	    mv $destpath $patchedpath
	fi
	patched+=("$patchedname")
	echo "Copied $filepath to $patchedpath"
    done

    echo "patching to fix the so names to the hashed names"
    for ((i=0;i<${#DEPS_LIST[@]};++i));
    do
	find onnx -name '*.so*' | while read sofile; do
	    origname=${DEPS_SONAME[i]}
	    patchedname=${patched[i]}
	    if [[ "$origname" != "$patchedname" ]]; then
		set +e
		patchelf --print-needed $sofile | grep $origname 2>&1 >/dev/null
		ERRCODE=$?
		set -e
		if [ "$ERRCODE" -eq "0" ]; then
		    echo "patching $sofile entry $origname to $patchedname"
		    patchelf --replace-needed $origname $patchedname $sofile
		fi
	    fi
	done
    done

    # set RPATH of _C.so and similar to $ORIGIN, $ORIGIN/lib
    find onnx -maxdepth 1 -type f -name "*.so*" | while read sofile; do
	echo "Setting rpath of $sofile to " '$ORIGIN:$ORIGIN/.lib'
	patchelf --set-rpath '$ORIGIN:$ORIGIN/.lib' $sofile
	patchelf --print-rpath $sofile
    done

    # set RPATH of lib/ files to $ORIGIN
    find onnx/.lib -maxdepth 1 -type f -name "*.so*" | while read sofile; do
	echo "Setting rpath of $sofile to " '$ORIGIN'
	patchelf --set-rpath '$ORIGIN' $sofile
	patchelf --print-rpath $sofile
    done


    # regenerate the RECORD file with new hashes
    record_file=`echo $(basename $whl) | sed -e 's/-cp.*$/.dist-info\/RECORD/g'`
    echo "Generating new record file $record_file"
    rm -f $record_file
    # generate records for onnx folder
    find onnx -type f | while read fname; do
	echo $(make_wheel_record $fname) >>$record_file
    done
    # generate records for onnx-[version]-dist-info folder
    find onnx*dist-info -type f | while read fname; do
	echo $(make_wheel_record $fname) >>$record_file
    done

    # zip up the wheel back
    zip -rq $(basename $whl) onnx*

    # replace original wheel
    rm -f $whl
    mv $(basename $whl) $whl
    cd ..
    rm -rf tmp
done

# Print out sizes of all wheels created
echo "Succesfulle made wheels of size:"
du -h /$WHEELHOUSE_DIR/onnx*.whl

# Copy wheels to host machine for persistence after the docker
mkdir -p /remote/$WHEELHOUSE_DIR
cp /$WHEELHOUSE_DIR/onnx*.whl /remote/$WHEELHOUSE_DIR/



package_name='onnx'
echo "Expecting the built wheels to be packages for '$package_name'"


