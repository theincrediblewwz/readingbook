#!/usr/bin/env python3
"""Measure the archived, instrumented Release app; never operate the installed app."""
import argparse, ctypes, datetime, hashlib, json, os, pathlib, re, shutil, signal, statistics, struct, subprocess, sys, time, uuid

TOOLS = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(subprocess.check_output(['git','-C',str(TOOLS),'rev-parse','--show-toplevel'],text=True).strip()).resolve()
SYSTEM = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
SYSTEM.mach_absolute_time.restype = ctypes.c_uint64
PROC=ctypes.CDLL('/usr/lib/libproc.dylib')
LAYOUT_WARNING_MARKERS=('being marked as needing layout','300 iterations')
DIAGNOSTIC_ENV_KEYS=frozenset(('READINGBOOK_DIAG_PAUSE_DOT','READINGBOOK_DIAG_SKIP_HIDDEN_WIDTH','READINGBOOK_DIAG_BIND_HIDDEN_THUMBNAILS'))

def diagnostic_environment(values):
    result={}
    for value in values:
        key,separator,setting=value.partition('=')
        if not separator or key not in DIAGNOSTIC_ENV_KEYS or setting not in ('0','1') or key in result:
            raise ValueError('diagnostic environment requires unique allowlisted NAME=0/1 values')
        result[key]=setting
    return result

def count_layout_warnings(value):
    # One warning line can contain both markers; count it once.
    return sum(any(marker in line for marker in LAYOUT_WARNING_MARKERS) for line in value.splitlines())

def diagnostic_metadata(profiled=False, scroll_metadata=None):
    # Keep the provenance on each result/summary, not only launch.json. Timing
    # aggregates remain available for diagnostics but are ineligible as ordinary
    # startup/action baselines when a sampler or injected scroll driver is present.
    reasons=[]
    if profiled:reasons.append('startup-sample')
    if scroll_metadata is not None:reasons.append('in-process-scroll-driver')
    return {'profiled':bool(profiled),'scrollDiagnostic':scroll_metadata,
        'latencyBaselineExcluded':bool(reasons),'latencyBaselineExclusionReasons':reasons}

def process_start(pid):
    buffer=ctypes.create_string_buffer(1024)
    if PROC.proc_pid_rusage(pid,4,buffer)!=0:return None
    # SDK sys/resource.h rusage_info_v4: 16-byte UUID + eight UInt64 fields.
    return struct.unpack_from('Q',buffer.raw,80)[0]

def executable(pid):
    buffer=ctypes.create_string_buffer(4096)
    return os.fsdecode(buffer.value) if PROC.proc_pidpath(pid,buffer,len(buffer))>0 else None

def terminate_owned(pid,binary):
    if pid and [(current,name) for current,name in processes() if current==pid]==[(pid,str(binary))]:
        os.kill(pid,signal.SIGTERM)

def local(value):
    path = pathlib.Path(value).expanduser().resolve()
    if path == ROOT or ROOT not in path.parents: raise ValueError('path must be inside workspace: '+str(path))
    return path

def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''): result.update(chunk)
    return result.hexdigest()

def tree_manifest(path):
    return {p.relative_to(path).as_posix():sha(p) for p in sorted(path.rglob('*')) if p.is_file()}

def write(path,value): path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')

def processes():
    rows = subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
    return [(int(line.strip().split(None,1)[0]),line.strip().split(None,1)[1]) for line in rows.splitlines() if len(line.strip().split(None,1))==2]

def preflight():
    blockers = [(pid,name) for pid,name in processes() if pathlib.Path(name).name in ('swift-frontend','swift-build','swiftc','swift-driver','ReadingBook')]
    if blockers: raise RuntimeError('close compiler/UI processes before timing: '+repr(blockers))

def collect_os_state(destination):
    # Only this diagnostic bundle's OS-created state. It never uses the real app domain.
    paths = [pathlib.Path.home()/'Library/Preferences/org.readingbook.perf-harness.plist',
             pathlib.Path.home()/'Library/Saved Application State/org.readingbook.perf-harness.savedState']
    stderr=destination.parent/'stderr.log'
    if stderr.exists():
        for value in re.findall(r'New state will be written to (.+)',stderr.read_text()):
            path=pathlib.Path(value.strip()).resolve()
            if path.name=='org.readingbook.perf-harness.savedState' and path.parts[:4]==('/','private','var','folders'):
                paths.append(path)
    for path in paths:
        if path.exists():
            destination.mkdir(parents=True,exist_ok=True)
            shutil.move(str(path),str(destination/path.name))
    # Invalidate this domain in cfprefsd as well as collecting its file.
    cleanup=subprocess.run(['/usr/bin/defaults','delete','org.readingbook.perf-harness'],capture_output=True,text=True,timeout=10)
    destination.mkdir(parents=True,exist_ok=True)
    write(destination/'defaults-cleanup.json',{'returnCode':cleanup.returncode,'stderr':cleanup.stderr})

def events(path):
    rows=[]
    if path.exists():
        for line in path.read_text().splitlines():
            try: rows.append(json.loads(line))
            except json.JSONDecodeError: pass
    return sorted(rows,key=lambda row:row.get('ticks',0))

def summarize(rows,launch,created=None):
    completed_ticks=next((row['ticks'] for row in rows if row['event']=='run.completed'),None)
    if completed_ticks is not None:rows=[row for row in rows if row['ticks']<=completed_ticks]
    main = next((row for row in rows if row['event']=='main.entry'),None)
    if not main: return {'status':'failed','reason':'missing main.entry'}
    factor = main['timebaseNumer']/main['timebaseDenom']/1e9
    def at(name): return next((row['ticks'] for row in rows if row['event']==name),None)
    def duration(begin,end):
        first,last=at(begin),at(end)
        return (last-first)*factor if first is not None and last is not None else None
    boundaries={name:(row['ticks']-launch)*factor for name in ['main.entry','appstore.init.begin','appstore.init.end','store.load.request','library.load-report.end','store.load.completed','reader.layout-ready','startup.reader.main-queue-echo','import.reader.main-queue-echo'] if (row:=next((r for r in rows if r['event']==name),None))}
    segments={name:duration(begin,end) for name,begin,end in [
        ('appstoreInit','appstore.init.begin','appstore.init.end'),('libraryLoadReport','library.load-report.begin','library.load-report.end'),
        ('storeLoad','store.load.request','store.load.completed'),('importParse','import.parse.request','import.parse.completed'),
        ('importPDFText','import.pdf-text.begin','import.pdf-text.end'),('importRepositoryCreate','import.repository-create.begin','import.repository-create.end'),
        ('importSourceCopy','import.source-copy.begin','import.source-copy.end'),('firstPDFDocumentCreate','pdf.document-create.begin','pdf.document-create.end'),
        ('firstPDFPosition','pdf.position.begin','pdf.position.end')]}
    actions=[]; pending=None; occurrences={}
    for row in rows:
        if row['event']=='action.begin': pending=row
        elif row['event']=='action.end' and pending:
            action={**{k:v for k,v in row.items() if k not in ('event','ticks')},'seconds':(row['ticks']-pending['ticks'])*factor}
            if action['kind']=='page':
                key=(action['round'],action['page']);occurrences[key]=occurrences.get(key,0)+1;action['pageOccurrence']=occurrences[key]
            actions.append(action)
            pending=None
    resources=[]; last={}
    def cpu_ticks(row,kind):
        return row.get(kind+'CPUTimeMachTicks',row.get(kind+'CPUTimeNanoseconds',0))
    for row in rows:
        if row['event']!='resource.sample': continue
        result={**row,'secondsAfterLaunchRequest':(row['ticks']-launch)*factor}
        for kind in ('user','system'):
            value=cpu_ticks(row,kind)
            result.pop(kind+'CPUTimeNanoseconds',None)
            result[kind+'CPUTimeMachTicks']=value
            result['cumulative'+kind.title()+'CPUSeconds']=value*factor
        previous=last.get(row['pid'])
        if previous and row['ticks']>previous['ticks']:
            cpu=sum(cpu_ticks(row,kind)-cpu_ticks(previous,kind) for kind in ('user','system'))*factor
            result['cpuPercentOfOneCore']=100*cpu/((row['ticks']-previous['ticks'])*factor)
        resources.append(result);last[row['pid']]=row
    reader_baseline=at('startup.reader.main-queue-echo') or at('import.reader.main-queue-echo')
    foreground=[row for row in rows if row['event']=='window.foreground' and reader_baseline is not None and row['ticks']>=reader_baseline]
    initial_window=[row for row in rows if row['event']=='window.foreground' and (reader_baseline is None or row['ticks']<reader_baseline)]
    obscured=[row for row in foreground if not all(row.get(key,False) for key in ('appActive','keyWindow','windowVisible','occlusionVisible'))]
    completed=next((row for row in rows if row['event']=='run.completed'),None)
    failures=[row for row in rows if row['event'] in ('run.failed','watchdog.main-stall')]
    pulses=[(r['ticks']-r['queuedTicks'])*factor for r in rows if r['event']=='heartbeat']
    process_boundaries={name:(at(name)-created)*factor for name in boundaries} if created is not None else {}
    return {'status':'passed' if completed and not failures else 'failed','launchRequestBoundariesSeconds':boundaries,'processCreateBoundariesSeconds':process_boundaries,'segmentsSeconds':segments,
        'actions':actions,'resources':resources,'initialWindowLifecycle':initial_window,'foregroundEligibilityBoundary':'startup/import reader state-main-queue-echo and subsequent reading actions','firstPDFLayoutForeground':next((row for row in rows if row['event']=='window.foreground' and row.get('label')=='pdf-layout-ready'),None),'foregroundEligible':bool(foreground) and not obscured,'foregroundExceptions':obscured,
        'maxMainQueueLagSeconds':max(pulses,default=0),'failures':failures,'completion':completed,
        'resourceCounterSchema':'rusage user/system are mach ticks; legacy raw Nanoseconds field names normalized with event timebase',
        'measurementLimits':['layout-ready is native PDF navigation settle, not pixel first screen','tab/close are state to two main queue echoes, not composited frame latency','page actions call navigateToUnit; no scroll FPS or button latency measured','fresh processes and libraries; disk caches were not purged']}

def aggregate(results):
    groups={}
    for result in results:
        for key,value in result.get('launchRequestBoundariesSeconds',{}).items(): groups.setdefault('launch-request→'+key,[]).append(value)
        for key,value in result.get('processCreateBoundariesSeconds',{}).items(): groups.setdefault('process-create→'+key,[]).append(value)
        for key,value in result.get('segmentsSeconds',{}).items():
            if value is not None:groups.setdefault(key,[]).append(value)
        for action in result.get('actions',[]):
            key=('first-session' if action['round']==0 else 'same-process-warm')+':'+action['kind']
            if 'page' in action:key+=':'+str(action['page'])+':occurrence-'+str(action.get('pageOccurrence',1))
            groups.setdefault(key,[]).append(action['seconds'])
    return {key:{'count':len(values),'medianSeconds':statistics.median(values),'worstSeconds':max(values)} for key,values in sorted(groups.items())}

def stop_held(path):
    record=json.loads(local(path).read_text());pid=record['pid'];expected=record['executable']
    matches=[name for current,name in processes() if current==pid]
    if matches!=[expected]:raise RuntimeError('held PID no longer matches owned probe executable')
    os.kill(pid,signal.SIGTERM)
    for _ in range(100):
        if not any(current==pid for current,_ in processes()):break
        time.sleep(.1)
    else:raise RuntimeError('owned held probe did not exit')
    collect_os_state(local(path).parent/'collected-os-state')
    print('Stopped owned probe PID',pid)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',default='.build/perf-harness-20261028-release/build-manifest.json')
    parser.add_argument('--library-copy');parser.add_argument('--pdf');parser.add_argument('--book-id')
    parser.add_argument('--mode',choices=['load','import','warm'],default='load')
    parser.add_argument('--rounds',type=int,default=5);parser.add_argument('--warm-repeats',type=int,default=1,help='total action cycles in each process, including the first unprewarmed cycle')
    parser.add_argument('--width',type=int,default=1470);parser.add_argument('--height',type=int,default=843)
    parser.add_argument('--memory-offsets',default='');parser.add_argument('--tag',default=datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    parser.add_argument('--hold-final',action='store_true');parser.add_argument('--stop-held')
    parser.add_argument('--profile-startup',action='store_true',help='separate diagnostic sample; must never be included in performance baseline')
    parser.add_argument('--scroll-driver',help='workspace-built in-process diagnostic dylib; requires one held run, excluded from latency baselines')
    parser.add_argument('--diagnostic-env',action='append',default=[],help='allowlisted scroll-diagnostic NAME=0/1; repeated values forbidden')
    args=parser.parse_args()
    if args.stop_held:return stop_held(args.stop_held)
    scroll_driver=local(args.scroll_driver) if args.scroll_driver else None
    diagnostic_env=diagnostic_environment(args.diagnostic_env)
    if diagnostic_env and not scroll_driver:
        raise ValueError('experimental component switches require an isolated scroll diagnostic')
    if scroll_driver and (not scroll_driver.is_file() or not args.hold_final or args.rounds!=1):
        raise ValueError('scroll diagnostic requires an existing workspace library and one --hold-final run')
    if not args.tag.replace('-','').replace('_','').isalnum():raise ValueError('tag must be alphanumeric with hyphens/underscores')
    manifest=json.loads(local(args.manifest).read_text());base=local(manifest['buildRoot']);app=local(manifest['app']);binary=app/'Contents/MacOS/ReadingBook'
    if manifest.get('configuration')!='release' or not manifest.get('buildSucceeded') or sha(binary)!=manifest['binarySHA256']:raise RuntimeError('successful unmodified Release build required')
    fixture=local(args.library_copy) if args.library_copy else None
    pdf=local(args.pdf) if args.pdf else None
    if args.mode!='import' and not fixture:raise ValueError('--library-copy required for load/warm')
    if args.mode=='import' and not pdf:raise ValueError('--pdf required for import')
    if args.rounds<1 or args.warm_repeats<1:raise ValueError('positive rounds required')
    original=tree_manifest(fixture) if fixture else None
    pdf_before=sha(pdf) if pdf else None
    destination=base/'runs'/args.tag;destination.mkdir(parents=True,exist_ok=False)
    logroot=ROOT/'logs'/base.name/args.tag;logroot.mkdir(parents=True,exist_ok=False)
    write(logroot/'fixture-before.json',original)
    results=[]
    for index in range(args.rounds):
        preflight();run=destination/('run-'+str(index+1));run.mkdir();library=run/'library'
        write(run/'build-manifest.json',manifest)
        shutil.copy2(ROOT/'logs'/base.name/'instrumentation.patch',run/'instrumentation.patch')
        if fixture and args.mode!='import':shutil.copytree(fixture,library)
        else:library.mkdir()
        source=None
        if pdf and args.mode=='import':
            (run/'input').mkdir();source=run/'input'/pdf.name;shutil.copy2(pdf,source)
        projects=list((library/'books').glob('*/project.json')) if (library/'books').exists() else []
        bookid=args.book_id or (json.loads(projects[0].read_text())['id'] if len(projects)==1 else None)
        if args.mode!='import' and not bookid:raise ValueError('unambiguous --book-id required')
        config={'workspace':str(ROOT),'output':str(run),'library':str(library),'mode':args.mode,'source':str(source) if source else None,
            'bookID':bookid,'width':args.width,'height':args.height,'scale':3.43,'warmRepeats':args.warm_repeats,
            'memoryOffsets':[float(x) for x in args.memory_offsets.split(',') if x], 'hold':args.hold_final and index==args.rounds-1}
        write(run/'config.json',config);env=os.environ.copy();env['READINGBOOK_PERF_CONFIG']=str(run/'config.json');env['TMPDIR']=str(base/'tmp')
        start=datetime.datetime.now().astimezone();launcherlog=(run/'launcher.log').open('w')
        openargs=['/usr/bin/open','-n','-W','--env','READINGBOOK_PERF_CONFIG='+str(run/'config.json'),'--env','TMPDIR='+str(base/'tmp'),
            '--stdout',str(run/'stdout.log'),'--stderr',str(run/'stderr.log'),str(app)]
        scroll_metadata=None
        if scroll_driver:
            control=run/'scroll-control';control.mkdir()
            nonce=str(uuid.uuid4())
            driver_env={'DYLD_INSERT_LIBRARIES':str(scroll_driver),'READINGBOOK_SCROLL_WORKSPACE':str(ROOT),
                'READINGBOOK_SCROLL_EXPECTED_EXECUTABLE':str(binary),'READINGBOOK_SCROLL_CONTROL':str(control),'READINGBOOK_SCROLL_NONCE':nonce}
            effective_switches={key:diagnostic_env.get(key,'0') for key in sorted(DIAGNOSTIC_ENV_KEYS)}
            for key,value in {**driver_env,**effective_switches}.items():openargs[-1:-1]=['--env',key+'='+value]
            scroll_metadata={'library':str(scroll_driver),'sha256':sha(scroll_driver),'control':str(control),'nonce':nonce,'latencyBaselineExcluded':True,'componentSwitches':effective_switches}
        launch=SYSTEM.mach_absolute_time();child=subprocess.Popen(openargs,cwd=run,env=env,stdout=launcherlog,stderr=subprocess.STDOUT)
        apppid=None;created=None;sampler=None;samplelog=None
        launchrecord={'launchRequestTicks':launch,'launcherPID':child.pid,'startedAt':start.isoformat(),'binarySHA256':manifest['binarySHA256'],'sourceCommit':manifest['sourceCommit'],'launchMethod':'LaunchServices open -n -W with per-process environment'}
        if scroll_metadata:launchrecord['scrollDiagnostic']=scroll_metadata
        write(run/'launch.json',launchrecord)
        deadline=time.monotonic()+max(360,240+max(config['memoryOffsets'],default=0))
        held=False
        while child.poll() is None:
            current=events(run/'events.jsonl')
            if apppid is None and (entry:=next((row for row in current if row['event']=='main.entry'),None)):
                apppid=entry['pid'];created=process_start(apppid)
                observed=executable(apppid)
                if observed!=str(binary):raise RuntimeError('main.entry PID does not match the owned probe executable')
                if not created or created>entry['ticks']:raise RuntimeError('invalid app process creation clock')
                launchrecord.update(pid=apppid,executable=observed,processCreatedTicks=created,profiled=args.profile_startup);write(run/'launch.json',launchrecord)
                if args.profile_startup:
                    samplelog=(run/'sample-driver.log').open('w')
                    sampler=subprocess.Popen(['/usr/bin/sample',str(apppid),'5','10','-file',str(run/'startup.sample.txt')],stdout=samplelog,stderr=subprocess.STDOUT,env=env,cwd=run)
            if config['hold'] and any(row['event']=='run.completed' for row in current):
                held=True;write(run/'held-process.json',{'pid':apppid,'executable':str(binary),'config':str(run/'config.json')});child.terminate();child.wait(timeout=10);break
            if time.monotonic()>deadline:
                terminate_owned(apppid,binary);child.terminate()
                try:child.wait(timeout=10)
                except subprocess.TimeoutExpired:child.kill();child.wait()
                break
            time.sleep(.1)
        if sampler:
            try:sampler.wait(timeout=15)
            except subprocess.TimeoutExpired:sampler.terminate();sampler.wait(timeout=5)
            samplelog.close()
        launcherlog.close();rows=events(run/'events.jsonl');result=summarize(rows,launch,created)
        result.update(run=str(run),exitCode=child.poll(),held=held)
        result.update(diagnostic_metadata(args.profile_startup,scroll_metadata))
        if sampler:
            result['startupSampleReturnCode']=sampler.returncode
            if sampler.returncode!=0 or not (run/'startup.sample.txt').exists():result['status']='failed-startup-sample'
        if not held and child.returncode!=0:result['status']='failed'
        if result['status']=='passed' and not result.get('foregroundEligible',False):result['status']='ineligible-background'
        end=datetime.datetime.now().astimezone()
        logargs=['/usr/bin/log','show','--style','compact','--start',start.strftime('%Y-%m-%d %H:%M:%S'),'--end',end.strftime('%Y-%m-%d %H:%M:%S'),'--predicate','processIdentifier == '+str(apppid or -1)]
        try:log=subprocess.run(logargs,text=True,capture_output=True,timeout=30)
        except subprocess.TimeoutExpired as error:
            output=error.stdout or ''
            if isinstance(output,bytes):output=output.decode(errors='replace')
            log=subprocess.CompletedProcess(logargs,124,output,'system log collection exceeded 30 seconds\n')
        result['systemLogCollection']={'returnCode':log.returncode,'timeoutSeconds':30,'status':'collected' if log.returncode==0 else 'failed'}
        if log.returncode!=0:result['status']='failed-log-collection'
        (run/'system.log').write_text(log.stdout+log.stderr)
        text=((run/'stderr.log').read_text() if (run/'stderr.log').exists() else '')+log.stdout
        result['layoutWarningMarkers']=list(LAYOUT_WARNING_MARKERS)
        result['layoutDirtyWarnings']=count_layout_warnings(text)
        result['publishingWarnings']=text.count('Publishing changes from within view updates')
        if result['layoutDirtyWarnings'] or result['publishingWarnings']:result['status']='failed'
        write(run/'result.json',result);results.append(result)
        write(logroot/('run-'+str(index+1)+'-result.json'),result)
        print(json.dumps({'run':index+1,'status':result['status'],'foregroundEligible':result.get('foregroundEligible',False),'processCreateBoundariesSeconds':result.get('processCreateBoundariesSeconds'),'maxMainQueueLagSeconds':result.get('maxMainQueueLagSeconds'),'heldPID':apppid if held else None}),flush=True)
        if not held:collect_os_state(run/'collected-os-state')
        if result['status']!='passed':break
    after=tree_manifest(fixture) if fixture else None;write(logroot/'fixture-after.json',after)
    pdf_after=sha(pdf) if pdf else None
    summary={'status':'passed' if len(results)==args.rounds and all(r['status']=='passed' for r in results) and after==original and pdf_before==pdf_after else 'failed',
        'sourceLibraryUnchanged':after==original if fixture else None,'sourcePDFSHA256':pdf_before,'sourcePDFUnchanged':pdf_before==pdf_after if pdf else None,'mode':args.mode,'roundsRequested':args.rounds,'roundsCompleted':len(results),
        'window':[args.width,args.height],'aggregate':aggregate(results),'runs':[r['run'] for r in results],
        **diagnostic_metadata(args.profile_startup,next((r.get('scrollDiagnostic') for r in results if r.get('scrollDiagnostic') is not None),None)),
        'launchBoundary':'external mach_absolute_time before LaunchServices request; libproc ri_proc_start_abstime is separate process-create boundary; main.entry excludes pre-main',
        'diskColdCache':False,'pixelFirstScreenMeasured':False}
    write(logroot/'summary.json',summary);print('Summary:',logroot/'summary.json',flush=True)
    return 0 if summary['status']=='passed' else 1

if __name__=='__main__':
    try:sys.exit(main())
    except Exception as error:print(type(error).__name__+': '+str(error),file=sys.stderr);sys.exit(2)
