#!/usr/bin/env python3
"""Regenerate only synthetic fixtures. No device data is read by this script."""
import copy, hashlib, json, uuid
from pathlib import Path
from datetime import datetime, timezone, timedelta
ROOT=Path(__file__).resolve().parents[1]
BASE=datetime(2026,8,10,15,tzinfo=timezone.utc)
BASE_MS=int(BASE.timestamp()*1000)
DATASET='11111111-1111-4111-8111-111111111111'
def uid(n): return str(uuid.UUID(int=n))
def time(ms): return (BASE+timedelta(milliseconds=ms)).isoformat(timespec='milliseconds').replace('+00:00','Z')
def write(name,data): (ROOT/'fixtures'/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
source=dict(bundleIdentifier='example.synthetic.watch',sourceKey=hashlib.sha256(b'example.synthetic.watch').hexdigest(),name='合成测试来源',deviceType='watch',manufacturer=None,model=None,timeZone=None)
dataset=dict(datasetId=DATASET,historyStart=time(-86400000),sources=dict(sleep=source['bundleIdentifier'],workout=source['bundleIdentifier']))
workout=dict(start=time(0),end=time(3000000),startOffsetSeconds=28800,endOffsetSeconds=28800,source=copy.deepcopy(source),recordingMethod='active',warnings=[],sourceUuid=uid(50),appleActivityType='running',exerciseType='RUNNING',durationMs=2700000,indoor=False,pauses=[dict(start=time(1200000),end=time(1500000))],distance=dict(state='value',metres=5000.0),activeEnergy=dict(state='value',kcal=325.5))
workout_group=dict(changeSetId=uid(900),changes=[dict(entityId=f'hr1/{DATASET}/workout/{uid(50)}',version=9223372036854775806,kind='workout',action='upsert',payload=workout)])
write('workout.json',dict(dataset=dataset,group=workout_group))
cases=[]
def sample(n,a,b,value):return dict(uuid=uid(n),startMs=BASE_MS+a,endMs=BASE_MS+b,value=value,source=copy.deepcopy(source),recordingMethod='automatic')
def case(name,inputs,parts,warnings=(),now=86400000,history=-86400000,excluded=0,deferred=0):
    # Each explicit expected part: (anchor UUID number, [(start ms,end ms,stage type),...]).
    d=copy.deepcopy(dataset);d['historyStart']=time(history)
    expected=[]
    candidates=[]
    for item in sorted((x for x in inputs if x['value'] not in ['inBed'] and not x['value'].startswith('unknown')),key=lambda x:(x['startMs'],x['endMs'],x['uuid'])):
        if not candidates or item['startMs']-max(x['endMs'] for x in candidates[-1])>1800000:candidates.append([item])
        else:candidates[-1].append(item)
    for anchor,stages in parts:
        a,b=stages[0][0],stages[-1][1]
        p=dict(start=time(a),end=time(b),startOffsetSeconds=None,endOffsetSeconds=None,source=copy.deepcopy(source),recordingMethod='automatic',warnings=list(warnings),anchorSampleUuid=uid(anchor),sampleUuids=sorted(set(x['uuid'] for g in candidates if any(x['uuid']==uid(anchor) and x['startMs']<BASE_MS+b and x['endMs']>BASE_MS+a for x in g) for x in g)),stages=[dict(start=time(s),end=time(e),type=t)for s,e,t in stages])
        expected.append(dict(entityId=f'hr1/{DATASET}/sleep/{source["sourceKey"]}/{uid(anchor)}/{BASE_MS+a}',version=1,kind='sleep',action='upsert',payload=p))
    cases.append(dict(name=name,dataset=d,nowMs=BASE_MS+now,input=inputs,expected=expected,warnings=list(warnings),excludedMs=excluded,deferred=deferred))
H=3600000;M=60000
case('C06_continuous_midnight',[sample(1,0,8*H,'asleepCore')],[(1,[(0,8*H,'light')])])
case('C07_inbed_overlap',[sample(1,0,H,'asleepCore'),sample(2,-H,2*H,'inBed')],[(1,[(0,H,'light')])])
case('C08_unspecified',[sample(1,0,H,'asleepUnspecified')],[(1,[(0,H,'sleeping')])])
case('C08_inbed_only',[sample(1,0,H,'inBed')],[],warnings=['NO_SLEEP_EVIDENCE'])
case('C09_same_stage_overlap',[sample(1,0,H,'asleepCore'),sample(2,30*M,90*M,'asleepCore')],[(1,[(0,90*M,'light')])])
case('C09_conflicting_sleep',[sample(1,0,H,'asleepCore'),sample(2,20*M,40*M,'asleepDeep')],[(1,[(0,20*M,'light'),(20*M,40*M,'sleeping'),(40*M,H,'light')])],warnings=['CONFLICTING_SLEEP_STAGES'])
case('C31_awake_conflict',[sample(1,0,140*M,'asleepCore'),sample(2,H,80*M,'awake')],[(1,[(0,H,'light')]),(1,[(80*M,140*M,'light')])],warnings=['CONFLICTING_SLEEP_STAGES','SLEEP_SPLIT_FOR_UNCERTAINTY'],excluded=20*M)
case('C30_gap_20min',[sample(1,0,H,'asleepCore'),sample(2,80*M,140*M,'asleepDeep')],[(1,[(0,H,'light')]),(2,[(80*M,140*M,'deep')])],warnings=['SLEEP_SPLIT_FOR_UNCERTAINTY'],excluded=20*M)
case('C30_gap_1ms',[sample(1,0,H,'asleepCore'),sample(2,H+1,2*H+1,'asleepDeep')],[(1,[(0,H,'light')]),(2,[(H+1,2*H+1,'deep')])],warnings=['SLEEP_SPLIT_FOR_UNCERTAINTY'],excluded=1)
case('C30_awake_control',[sample(1,0,H,'asleepCore'),sample(2,H,80*M,'awake'),sample(3,80*M,140*M,'asleepDeep')],[(1,[(0,H,'light'),(H,80*M,'awake'),(80*M,140*M,'deep')])])
case('C10_exact_30min',[sample(1,0,H,'asleepCore'),sample(2,90*M,150*M,'asleepCore')],[(1,[(0,H,'light')]),(2,[(90*M,150*M,'light')])],warnings=['SLEEP_SPLIT_FOR_UNCERTAINTY'],excluded=30*M)
case('C10_over_30min',[sample(1,0,H,'asleepCore'),sample(2,90*M+1,150*M+1,'asleepCore')],[(1,[(0,H,'light')]),(2,[(90*M+1,150*M+1,'light')])])
case('C10_open_deferred',[sample(1,0,H,'asleepCore')],[],warnings=['DEFERRED_OPEN_SLEEP'],now=H+30*M-1,deferred=1)
case('C28_closed_without_new_anchor',[sample(1,0,H,'asleepCore')],[(1,[(0,H,'light')])],now=H+30*M)
case('C28_cross_history_start',[sample(1,0,8*H,'asleepCore')],[(1,[(0,8*H,'light')])],history=4*H)
case('C09_awake_over_unspecified',[sample(1,0,H,'asleepUnspecified'),sample(2,20*M,40*M,'awake')],[(1,[(0,20*M,'sleeping'),(20*M,40*M,'awake'),(40*M,H,'sleeping')])])
case('unknown_is_not_sleep',[sample(1,0,H,'unknown:99')],[],warnings=['UNSUPPORTED_SLEEP_VALUE','NO_SLEEP_EVIDENCE'])
case('C10_abnormal_36h',[sample(1,0,36*H+1,'asleepCore')],[],warnings=['SLEEP_GROUP_TOO_LARGE'],now=40*H)
write('sleep-normalization.json',cases)
invalid=[]
def bad(name,mutate):
    g=copy.deepcopy(workout_group);mutate(g);invalid.append(dict(name=name,group=g))
bad('negative_distance',lambda g:g['changes'][0]['payload']['distance'].update(metres=-1))
bad('wrong_identity',lambda g:g['changes'][0].update(entityId=f'hr1/{DATASET}/workout/{uid(51)}'))
bad('wrong_source_hash',lambda g:g['changes'][0]['payload']['source'].update(sourceKey='0'*64))
bad('zero_version',lambda g:g['changes'][0].update(version=0))
bad('fractional_version',lambda g:g['changes'][0].update(version=1.5))
bad('overflow_version',lambda g:g['changes'][0].update(version=9223372036854775808))
bad('unknown_action',lambda g:g['changes'][0].update(action='clearAll'))
bad('missing_required',lambda g:g['changes'][0]['payload'].pop('durationMs'))
bad('invalid_offset',lambda g:g['changes'][0]['payload'].update(endOffsetSeconds=64801))
bad('non_millisecond_time',lambda g:g['changes'][0]['payload'].update(start='2026-08-10T15:00:00Z'))
bad('overlapping_pause',lambda g:g['changes'][0]['payload']['pauses'].append(copy.deepcopy(g['changes'][0]['payload']['pauses'][0])))
bad('unknown_exercise',lambda g:g['changes'][0]['payload'].update(exerciseType='MAGIC'))
bad('unknown_warning',lambda g:g['changes'][0]['payload'].update(warnings=['MAGIC']))
bad('wrong_statistic_unit',lambda g:g['changes'][0]['payload']['distance'].update(kcal=1))
bad('inconsistent_pause_duration',lambda g:g['changes'][0]['payload'].update(durationMs=1000))
bad('invalid_delete_identity',lambda g:g['changes'][0].update(action='delete',payload=None,entityId=f'hr1/{DATASET}/workout/not-a-uuid'))
write('invalid-contract.json',dict(dataset=dataset,cases=invalid))
write('README.json',dict(synthetic=True,description='全部记录为固定时间和人工构造的合成数据；不含用户健康记录。',generator='scripts/make-fixtures.py'))
