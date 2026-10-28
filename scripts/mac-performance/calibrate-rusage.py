#!/usr/bin/env python3
"""Offline, self-only CPU counter unit check; do not run during a benchmark."""
import argparse
import ctypes
import json
import os
import pathlib
import struct
import subprocess
import time

TOOLS=pathlib.Path(__file__).resolve().parent
ROOT=pathlib.Path(subprocess.check_output(['git','-C',str(TOOLS),'rev-parse','--show-toplevel'],text=True).strip()).resolve()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',default='logs/mac-performance/rusage-calibration.json')
    parser.add_argument('--duration',type=float,default=.2,help='self-only busy-loop seconds, 0.1 through 2')
    args=parser.parse_args()
    output=pathlib.Path(args.output).expanduser().resolve()
    if ROOT not in output.parents:raise ValueError('output must resolve inside workspace')
    if not .1<=args.duration<=2:raise ValueError('duration must be 0.1 through 2 seconds')
    lib=ctypes.CDLL('/usr/lib/libproc.dylib')
    system=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    class Timebase(ctypes.Structure):
        _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
    timebase=Timebase()
    if system.mach_timebase_info(ctypes.byref(timebase))!=0:raise RuntimeError('mach_timebase_info failed')
    factor=timebase.numer/timebase.denom/1e9
    def counters():
        buffer=ctypes.create_string_buffer(1024)
        if lib.proc_pid_rusage(os.getpid(),4,buffer)!=0:raise RuntimeError('self proc_pid_rusage failed')
        # SDK sys/resource.h rusage_info_v4: UUID[16], user, system.
        return struct.unpack_from('QQ',buffer.raw,16)
    before=counters();started=time.process_time();end=time.monotonic()+args.duration
    while time.monotonic()<end:pass
    stopped=time.process_time();after=counters();delta=sum(after)-sum(before)
    posix=stopped-started
    result={'pid':os.getpid(),'selfOnly':True,'timebaseNumer':timebase.numer,'timebaseDenom':timebase.denom,
        'rusageRawDelta':delta,'rusageMachConvertedSeconds':delta*factor,'posixProcessTimeSeconds':posix,
        'incorrectRawDividedBy1e9':delta/1e9,'relativeDifference':abs(delta*factor-posix)/posix,
        'sourceEvidence':['https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c',
                          'https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c']}
    result['status']='passed' if result['relativeDifference']<.05 else 'failed'
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    return 0 if result['status']=='passed' else 1

if __name__=='__main__':
    raise SystemExit(main())
