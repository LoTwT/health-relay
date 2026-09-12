#!/usr/bin/env python3
"""Machine-readable protocol v1 structural contract; semantic guards live in both apps."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
def obj(properties,required=None,extra=False):return dict(type='object',properties=properties,required=list(properties) if required is None else required,additionalProperties=extra)
def ref(name):return {'$ref':'#/$defs/'+name}
def arr(item,**kw):return dict(type='array',items=item,**kw)
def enum(*values):return dict(enum=list(values))
string={'type':'string','minLength':1,'maxLength':120}
uuid={'type':'string','pattern':'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'}
time={'type':'string','pattern':r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$','format':'date-time'}
def nullable(x):return {'anyOf':[x,{'type':'null'}]}
source=obj(dict(bundleIdentifier=dict(type='string',minLength=1,maxLength=255),sourceKey=dict(type='string',pattern='^[0-9a-f]{64}$'),**{k:nullable(string)for k in ['name','deviceType','manufacturer','model','timeZone']}))
common=dict(start=ref('time'),end=ref('time'),startOffsetSeconds=nullable(dict(type='integer',minimum=-64800,maximum=64800)),endOffsetSeconds=nullable(dict(type='integer',minimum=-64800,maximum=64800)),source=ref('source'),recordingMethod=enum('automatic','active','manual','unknown'),warnings=arr(dict(type='string',pattern='^[A-Z_]+$'),maxItems=100))
def statistic(unit):return {'oneOf':[obj(dict(state={'const':'unavailable'})),obj(dict(state={'const':'value'},**{unit:dict(type='number',minimum=0)}))]}
sleep=obj(dict(**common,anchorSampleUuid=ref('uuid'),sampleUuids=arr(ref('uuid'),minItems=1,maxItems=10000,uniqueItems=True),stages=arr(ref('stage'),minItems=1,maxItems=10000)))
workout=obj(dict(**common,sourceUuid=ref('uuid'),appleActivityType=string,exerciseType=string,durationMs=dict(type='integer',minimum=1,maximum=9223372036854775807),indoor=nullable(dict(type='boolean')),pauses=arr(ref('interval'),maxItems=10000),distance=statistic('metres'),activeEnergy=statistic('kcal')))
base=dict(entityId={'type':'string','pattern':'^hr1/'},version=dict(type='integer',minimum=1,maximum=9223372036854775807),kind=enum('sleep','workout'),action=enum('upsert','delete'))
change={'oneOf':[obj(dict(**{**base,'kind':{'const':k},'action':{'const':'upsert'}},payload=ref(k)))for k in ['sleep','workout']]+[obj({**base,'action':{'const':'delete'}})]}
defs=dict(uuid=uuid,time=time,source=source,sources=obj(dict(sleep=nullable(dict(type='string',minLength=1,maxLength=255)),workout=nullable(dict(type='string',minLength=1,maxLength=255)))),interval=obj(dict(start=ref('time'),end=ref('time'))),stage=obj(dict(start=ref('time'),end=ref('time'),type=enum('sleeping','light','deep','rem','awake'))),sleep=sleep,workout=workout,change=change,changeSet=obj(dict(changeSetId=ref('uuid'),changes=arr(ref('change'),minItems=1))))
defs['rebuildPlan']=obj(dict(planId=ref('uuid'),oldDatasetId=nullable(ref('uuid')),newDatasetId=ref('uuid'),historyStart=ref('time'),sources=ref('sources')))
def envelope(kind,fields):return obj(dict(protocolVersion={'const':1},type={'const':kind},requestId=ref('uuid'),**fields))
messages=[envelope('pair',dict(pairingId=ref('uuid'),pairingSecret=string,senderId=ref('uuid'),senderName=string,mode=enum('normal','recovery'),datasetId=nullable(ref('uuid')))),envelope('hello',dict(pairId=ref('uuid'),pairToken=string,senderId=ref('uuid'),receiverId=ref('uuid'),mode={'const':'normal'},datasetId=ref('uuid'),historyStart=ref('time'),sources=ref('sources'))),envelope('hello',dict(pairId=ref('uuid'),pairToken=string,senderId=ref('uuid'),receiverId=ref('uuid'),mode={'const':'recovery'},datasetId=nullable(ref('uuid')))),envelope('applyBatch',dict(generationId=ref('uuid'),batchId=ref('uuid'),changeSets=arr(ref('changeSet'),minItems=1,maxItems=25))),envelope('prepareRebuild',dict(rebuildPlan=ref('rebuildPlan'))),envelope('finish',dict(generationId=ref('uuid'))),envelope('unpair',{})]
schema={'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:health-relay:protocol:1','title':'health-relay protocol v1','$defs':defs,'oneOf':messages}
(root/'protocol'/'v1.schema.json').write_text(json.dumps(schema,ensure_ascii=False,indent=2)+'\n')
