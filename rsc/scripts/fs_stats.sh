#!/bin/bash

# Written by Andreas Heckel
# University of Heidelberg
# heckelandreas@googlemail.com
# https://github.com/ahheckel
# 12/06/2012

set -e

trap 'echo "$0 : An ERROR has occured."' ERR

delJIDs() {
  if [ x"SGE_ROOT" != "x" ] ; then
     local jidfile="$1" ; local i="" ; local j=0
     for i in $(cat $jidfile) ; do
        qdel $i
        j=$[$j+1]
     done
  fi
  rm -f $jidfile
  if [ $j -eq 0 ] ; then echo "`basename $0`: no jobs left to erase (OK)." ; fi
}

Usage() {
    echo ""
    echo "Usage:   `basename $0` <SUBJECTS_DIR> <glm-dir> <out-dir> <measure> <smoothing-kernels(FWHM)> <do-resamp:0|1> <do-smooth:0|1> <do-glm:0|1> <do-glm_sim: 0|1> <Nsim> [<sge-logdir>]"
    echo "Example: `basename $0` ./subj/FS_subj ./grp/glm/FS_stats ./grp/FS_stats \"thickness\" \"5 10 15 20 25\" 1 1 1 1 5000 ./logs"
    echo ""
    exit 1 
}
  
# create temporary dir.
wdir=`pwd`/.FS_glm$$ ; mkdir -p $wdir

# create joblist file for SGE
echo "`basename $0`: touching SGE job control file in '$wdir'."
JIDfile="$wdir/$(basename $0)_$$.sge"
touch $JIDfile

# set exit trap
trap "set +e ; echo -e \"\n`basename $0`: cleanup: erasing Job-IDs in '$JIDfile'\" ; delJIDs $JIDfile ;  rm -f $wdir/* ; rmdir $wdir ; exit" EXIT

# declare vars
[ "$8" = "" ] && Usage
SUBJECTS_DIR="$1"
glmdir_FS="$2"
FSstatsdir="$3"
measures="$4"
krnls="$5"
resamp=$6
smooth=$7
glmstats=$8
glm_sim=$9
Nsim=${10}
logdir="${11}"
if [ "$logdir" = "" ] ; then logdir=/tmp ; fi
jid=1 # init jobID

# display info
echo ""
echo "`basename $0` : SUBJECTS_DIR     : $SUBJECTS_DIR"
echo "`basename $0` : glm-dir          : $glmdir_FS"
echo "`basename $0` : out-dir          : $FSstatsdir"
echo "`basename $0` : smoothing-krnls  : $krnls"
echo "`basename $0` : measures         : $measures"
echo "`basename $0` : do-resamp        : $resamp"
echo "`basename $0` : do-smooth        : $smooth"
echo "`basename $0` : do-glm           : $glmstats"
echo "`basename $0` : do-glm_sim       : $glm_sim"
echo "`basename $0` : Nsim             : $Nsim"
echo "`basename $0` : logdir           : $logdir"
echo ""

# source globalfuncs
source $(dirname $0)/globalfuncs

# check if designs present
if [ $(cat $glmdir_FS/designs | wc -l) -eq 0 ] ; then echo "$(basename $0): ERROR: no designs specified in '$glmdir_FS/designs' - exiting..." ; exit 1 ; fi

# make dest. directory
mkdir -p $FSstatsdir
mkdir -p $FSstatsdir/scripts

# checks
designs=$(cat $glmdir_FS/designs)
err=0
for design in $designs ; do
  type=$(echo $design | cut -d _ -f 1) ; if [ x"$type" != x"doss" -a x"$type" != x"dods" ] ; then echo "$(basename $0): ERROR: neither 'doss' or 'dods' specified as prefix of design directory: '$design' - exiting..." ; err=1 ; fi
  fsgd_file=$(ls $glmdir_FS/$design/*.fsgd) ; if [ x"$fsgd_file" = "x" ] ; then echo "$(basename $0): ERROR: .fsgd file not found in '$glmdir_FS/$design' - exiting..." ; err=1 ; fi
  mtx_files=$(ls $glmdir_FS/$design/*.mtx)
done
if [ $err -eq 1 ] ; then exit 1 ; fi

# resampling to FS average space
if [ $resamp -eq 1 ] ; then
       
  # cleanup mris_preproc
  echo "$(basename $0): cleaning up previously unfinished mris_preproc runs..."
  rm -rfv $FSstatsdir/tmp.mris_preproc.[0-9]*
  ##rm -fv  $FSstatsdir/*.mris_preproc.log.bak  
  echo "------------------------------"
  
  # now execute mris_preproc
  cmdtxt=$FSstatsdir/scripts/mris_preproc.cmd ; rm -f $cmdtxt
  for design in $designs ; do
    fsgd_file=$(ls $glmdir_FS/$design/*.fsgd)
    for hemi in lh rh ; do
      for measure in $measures ; do
        output=${design}.${hemi}.${measure}.mgh
        
        echo "$(basename $0): resampling data pertaining to design file '$fsgd_file' onto average subject (output: '${FSstatsdir}/$output')..."
        echo "    mris_preproc --fsgd ${fsgd_file} --target fsaverage --hemi ${hemi} --meas ${measure} --out ${FSstatsdir}/$output" >> $cmdtxt
      done # end measure
    done # end hemi
  done # end design
  jid=`fsl_sub -l $logdir -N $(basename $cmdtxt) -j $jid -t $cmdtxt` ; echo $jid >> $JIDfile
    
  echo "------------------------------"

  waitIfBusy $JIDfile
  
fi

waitIfBusy $JIDfile

# smoothing
if [ $smooth -eq 1 ] ; then
  cmdtxt=$FSstatsdir/scripts/mri_surf2surf.cmd ; rm -f $cmdtxt
  for design in $designs ; do
    for hemi in lh rh ; do
      for sm in $krnls ; do
        for measure in $measures ; do
          output=${design}.${hemi}.${measure}.s${sm}.mgh
          input=${FSstatsdir}/${design}.${hemi}.${measure}.mgh
          
          if [ ! -f $input ] ; then echo "$(basename $0): ERROR: file not found: '$input' - exiting." ; exit 1 ; fi
          
          echo "$(basename $0): smoothing with (kernel: ${sm}mm FWHM -> output: '${FSstatsdir}/$output')..."
          echo "    mri_surf2surf --hemi ${hemi} --s fsaverage --sval $input --fwhm ${sm} --cortex --tval ${FSstatsdir}/$output" >> $cmdtxt
        done # end measure
      done # end sm
    done # end hemi
  done # end design
  jid=`fsl_sub -l $logdir -N $(basename $cmdtxt) -j $jid -t $cmdtxt` ; echo $jid >> $JIDfile

  echo "------------------------------"
fi
  
waitIfBusy $JIDfile

# do glm
if [ $glmstats -eq 1 ] ; then
  cmdtxt=$FSstatsdir/scripts/mri_glmfit.cmd ; rm -f $cmdtxt
  for design in $designs ; do  
    mtx_files=$(ls $glmdir_FS/$design/*.mtx)
    fsgd_file=$(ls $glmdir_FS/$design/*.fsgd)
    type=$(echo $design | cut -d _ -f 1)
    for hemi in lh rh ; do
      for sm in $krnls ; do
        for mtx in $mtx_files ; do
          for measure in $measures ; do
            output=${design}.${hemi}.${measure}.s${sm}.glmdir
            input=${FSstatsdir}/${design}.${hemi}.${measure}.s${sm}.mgh
            
            if [ ! -f $input ] ; then echo "$(basename $0): ERROR: file not found: '$input' - exiting." ; exit 1 ; fi
            
            echo "$(basename $0): performing GLM analysis: glmdir: '$output' --- type: '$type' --- contrast: '$(basename $mtx)'"
            echo "    mri_glmfit --y $input --fsgd ${fsgd_file} $type --C ${mtx} --surf fsaverage ${hemi} --cortex --glmdir $FSstatsdir/${output}" >> $cmdtxt
          done # end measure
        done # end mtx
      done # end sm
    done # end hemi
  done # end design
  jid=`fsl_sub -l $logdir -N $(basename $cmdtxt) -j $jid -t $cmdtxt` ; echo $jid >> $JIDfile

  echo "------------------------------"

  waitIfBusy $JIDfile

  # copy files...
  ##make absolute paths
  ##if [ $(echo $glmdir_FS | grep ^/ | wc -l) -eq 0 ] ; then glmdir_FS=`pwd`/$glmdir_FS ; fi
  ##if [ $(echo $SUBJECTS_DIR | grep ^/ | wc -l) -eq 0 ] ; then SUBJECTS_DIR=`pwd`/$SUBJECTS_DIR ; fi
  ##if [ $(echo $FSstatsdir | grep ^/ | wc -l) -eq 0 ] ; then FSstatsdir=`pwd`/$FSstatsdir ; fi
  for design in $designs ; do
    mtx_files=$(ls $glmdir_FS/$design/*.mtx)
    for hemi in lh rh ; do
      for sm in $krnls ; do
        for measure in $measures ; do
          glmdir="$FSstatsdir/${design}.${hemi}.${measure}.s${sm}.glmdir"
          echo "$(basename $0): copying files to '$(basename $glmdir)'..."
          cp $fsgd_file $glmdir/
          cp $mtx_files $glmdir/
          
          for mtx in $mtx_files ; do      
            mtx=$(basename $mtx)
            if [ ! -d $glmdir/${mtx%%.mtx} ] ; then 
              echo "$(basename $0): ERROR: directory '$glmdir/${mtx%%.mtx}' does not exist! Maybe GLM has failed! Continuing loop..."
              err=1
              continue 
            fi
            #rel=`path_abs2rel $glmdir/ $SUBJECTS_DIR/fsaverage/`
            #ln -sf $rel/surf/${hemi}.inflated $glmdir/${hemi}.inflated        
            #ln -sf $rel/surf/${hemi}.curv $glmdir/${hemi}.curv
            #ln -sf $rel/label/${hemi}.aparc.a2009s.annot $glmdir/${hemi}.aparc.a2009s.annot
            cp $SUBJECTS_DIR/fsaverage/surf/${hemi}.inflated $glmdir/${mtx%%.mtx}/
            cp $SUBJECTS_DIR/fsaverage/surf/${hemi}.curv $glmdir/${mtx%%.mtx}/
            cp $SUBJECTS_DIR/fsaverage/label/${hemi}.aparc.a2009s.annot $glmdir/${mtx%%.mtx}/
       
            cp -P $SUBJECTS_DIR/fsaverage $glmdir/${mtx%%.mtx}/ # copy the symbolic links
          done
          echo "------------------------------"
        done # end measure
      done # end sm
    done # end hemi
  done # end design
fi

waitIfBusy $JIDfile

if [ $glm_sim -eq 1 ] ; then
  cmdtxt=$FSstatsdir/scripts/mri_glmfit-sim.cmd ; rm -f $cmdtxt
  for design in $designs ; do
    for hemi in lh rh ; do
      for sm in $krnls ; do
        for measure in $measures ; do
          glmdir="$FSstatsdir/${design}.${hemi}.${measure}.s${sm}.glmdir"
          # cleanup mri_glmfit-sim 
          echo "$(basename $0): $glmdir: cleaning up previously unfinished mri_glmfit-sim runs..."
          rm -rfv $glmdir/tmp.mri_glmfit-sim-[0-9]*
          for sign in neg pos ; do
            for thresh in 2.0000 2.3010 3 3.3010 4.0000 ; do
              input=${design}.${hemi}.${measure}.s${sm}.mgh

              ln -sf ../$input $glmdir/$input
              echo "$(basename $0): permutation testing in '$glmdir' (sign: $sign , thres: $thresh, N=${Nsim})"
              echo "    mri_glmfit-sim --glmdir $glmdir --sim mc-z $Nsim $thresh mc-z.${sign}.${thresh} --sim-sign $sign --cwpvalthresh 0.05 --overwrite" >> $cmdtxt
            done # thres
          done # sign
        done # measure
      done # sm
    done # hemi
  done # design
  #jid=`fsl_sub -l $logdir -N $(basename $cmdtxt) -j $jid -t $cmdtxt` ; echo $jid >> $JIDfile
  . $cmdtxt # because of NFS stale error

  echo "------------------------------"
fi

waitIfBusy $JIDfile

echo "$(basename $0): done."
