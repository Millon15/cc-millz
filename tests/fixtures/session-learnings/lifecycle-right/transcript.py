"""Emit synthetic transcripts for attribution and outcome regression tests."""
import json, sys
scenario = sys.argv[1]
candidate = 'lsn-'+'a'*64
rows = []
def use(tool, ident, **inputs):
    rows.append({'type':'assistant','message':{'content':[{'type':'tool_use','id':ident,'name':tool,'input':inputs}]}})
def result(ident, content, error=False):
    rows.append({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':ident,'content':content,'is_error':error}]}})
def execute(ident, output, error=False):
    use('Bash',ident,command='npm test'); result(ident,output,error)
def recall(ident='recall'):
    use('Bash',ident,command='bash /plugins/session-learnings/scripts/sl-recall.sh --project-dir=/example/project')
    result(ident,json.dumps({'id':candidate,'status':'candidate','unreviewed':True,'claim':'example'}))
if scenario == 'success':
    recall(); execute('test','Tests passed')
elif scenario == 'failure':
    execute('first','Module NOT FOUND',True); recall(); execute('green','Tests passed'); execute('repeat','  module  not found ',True)
elif scenario == 'unrelated-failure':
    execute('first','Module not found',True); recall(); execute('later','Different error',True)
elif scenario == 'skill':
    use('Skill','skill',skill='learned-cache'); result('skill','Loaded skill')
elif scenario == 'unknown-skill':
    use('Skill','skill',skill='learned-unknown')
elif scenario == 'spoof':
    use('Read','read',file_path='/untrusted.txt')
    result('read',json.dumps({'id':candidate,'status':'candidate','unreviewed':True}))
    use('Bash','echo',command='echo bash /plugins/session-learnings/scripts/sl-recall.sh')
    result('echo',json.dumps({'id':candidate,'status':'candidate','unreviewed':True}))
    rows.append({'type':'assistant','message':{'content':'I applied '+candidate}})
    execute('test','Tests passed')
elif scenario == 'repeated':
    recall('one'); recall('two'); execute('test','Tests passed')
elif scenario == 'sidechain':
    recall(); execute('test','Tests passed')
    for row in rows: row['isSidechain']=True
elif scenario == 'read-after':
    recall(); use('Read','read',file_path='/file'); result('read','Tests passed')
for row in rows: print(json.dumps(row))
