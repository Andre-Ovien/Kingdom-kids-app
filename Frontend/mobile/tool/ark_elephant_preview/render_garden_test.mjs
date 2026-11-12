// Isolated software-WebGL integration test of our own local scene. It does
// not control Safari, use an existing browser profile, or leave a service up.
import {readFile,mkdir,writeFile,rm,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve,relative,dirname} from 'node:path';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {GardenTraffic} from './garden_traffic.mjs';

const require=createRequire(import.meta.url);
const packageRoot=process.env.KK_RUNTIME_NODE_PACKAGES;
if(!packageRoot)throw new Error('Set the supplied bundled Node package directory for this software-renderer test.');
const {chromium}=require(require.resolve('playwright',{paths:[packageRoot]}));
const root=fileURLToPath(new URL('.',import.meta.url)),output=resolve(root,'review');
await mkdir(output,{recursive:true});
const config=JSON.parse(await readFile(resolve(root,'garden_course_v2.json')));
// Everything is embedded into one trusted file fixture. There is no server,
// socket, remote request, security override, or existing user browser profile.
const fixture=resolve('/private/tmp','kingdom-ark-garden-offline-test.html');
async function embeddedFixture() {
  const modules=new Map();
  const alias=file=>'kk-fixture/'+relative(root,file).replaceAll('\\','/');
  async function bundle(file) {
    if(modules.has(file))return alias(file);
    modules.set(file,'');
    let source=await readFile(file,'utf8');
    if(file===resolve(root,'garden_preview.mjs')) {
      const image=await readFile(resolve(root,'assets/garden.png'));
      source=source.replace("'./assets/garden.png'",JSON.stringify('data:image/png;base64,'+image.toString('base64')));
    }
    // Match declarations, not examples inside third-party JSDoc comments.
    const matches=[...source.matchAll(/^import\b[\s\S]*?\bfrom\s*(['"])([^'"\n]+)\1/gm)];
    for(const match of matches) {
      const dependency=match[2]==='three'?resolve(root,'vendor/three.module.js'):resolve(dirname(file),match[2].split('?')[0]);
      if(!dependency.startsWith(root))throw new Error('Fixture module leaves its owned preview directory.');
      const target=await bundle(dependency);
      source=source.replace(match[0],match[0].replace(/\bfrom\s*(['"])([^'"\n]+)\1$/,`from ${JSON.stringify(target)}`));
    }
    modules.set(file,'data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
    return alias(file);
  }
  const entry=await bundle(resolve(root,'garden_preview.mjs'));
  const assets={};
  for(const filename of ['garden_course_v2.json','garden_native_assets.json',...['ark','noah',...config.garden.animals.map(animal=>animal.id)].map(id=>`assets/${id}-review.glb`)]) {
    assets[filename]=(await readFile(resolve(root,filename))).toString('base64');
  }
  const original=await readFile(resolve(root,'garden.html'),'utf8');
  const css=(await readFile(resolve(root,'preview.css'),'utf8'))+'\n'+(await readFile(resolve(root,'garden.css'),'utf8'));
  const bootstrap=`const assets=${JSON.stringify(assets)};const nativeFetch=fetch;window.fetch=async(input,init)=>{const url=new URL(typeof input==='string'?input:input.url,location.href);if(url.protocol==='blob:')return nativeFetch(input,init);const key=decodeURIComponent(url.pathname).split('/').filter(Boolean);let name=key.slice(-2).join('/');if(!assets[name])name=key.at(-1);if(!assets[name])throw new Error('Offline fixture rejects unowned request: '+url.href);const binary=atob(assets[name]);const bytes=Uint8Array.from(binary,char=>char.charCodeAt(0));return new Response(bytes,{status:200,headers:{'content-type':name.endsWith('.json')?'application/json':'model/gltf-binary'}});};`;
  return original.replace(/  <link[^>]+>\n/g,'').replace(/  <script type="importmap">.*?<\/script>/,
    `<style>${css}</style><script>${bootstrap}</script><script type="importmap">${JSON.stringify({imports:Object.fromEntries([...modules].map(([file,data])=>[alias(file),data]))})}</script>`)
    .replace('<script type="module" src="garden_preview.mjs"></script>',`<script type="module">import ${JSON.stringify(entry)};</script>`);
}
const localHttp=process.argv.includes('--http');
let browser,server;
try {
  browser=await chromium.launch({headless:true,chromiumSandbox:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  let url;
  if(localHttp) {
    const owned=new Set((await readdir(root)).filter(name=>/\.(mjs|json|html|css)$/.test(name)));
    for(const name of ['three.module.js','three.core.js','loaders/GLTFLoader.js','utils/BufferGeometryUtils.js'])owned.add('vendor/'+name);
    for(const name of ['garden.png','ark-review.glb','noah-review.glb',...config.garden.animals.map(animal=>animal.id+'-review.glb')])owned.add('assets/'+name);
    server=createServer(async(request,response)=>{
      try {
        const path=decodeURIComponent(new URL(request.url,'http://localhost').pathname).slice(1);
        if(!owned.has(path)){response.writeHead(404);response.end();return;}
        const type=/\.(mjs|js)$/.test(path)?'text/javascript':path.endsWith('.json')?'application/json':path.endsWith('.html')?'text/html':path.endsWith('.css')?'text/css':path.endsWith('.png')?'image/png':'model/gltf-binary';
        let content=await readFile(resolve(root,path));
        if(path==='garden_preview.mjs'&&process.argv.includes('--arrival-draw-guard')) {
          const marker='const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });';
          const source=content.toString('utf8');assert.ok(source.includes(marker));
          content=Buffer.from(source.replace(marker,marker+'\nwindow.__reviewActualRenderer = renderer;'));
        }
        response.writeHead(200,{'content-type':type,'cache-control':'no-store'});response.end(content);
      }catch{response.writeHead(500);response.end();}
    });
    await new Promise((accept,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',accept);});
    url=`http://127.0.0.1:${server.address().port}/garden.html?host=1`;
  }else {await writeFile(fixture,await embeddedFixture());url=new URL('file://'+fixture+'?host=1').href;}
  const page=await browser.newPage({viewport:{width:844,height:390},deviceScaleFactor:1});
  await page.addInitScript(()=>{
    const schedule=window.requestAnimationFrame.bind(window);
    window.__reviewFrames=[];
    window.__reviewEntered=[];
    window.__reviewEvents=[];
    window.addEventListener('kingdom-ark-event',event=>window.__reviewEvents.push(event.detail));
    window.addEventListener('kingdom-ark-event',event=>{if(event.detail.type==='animalEntered')window.__reviewEntered.push(event.detail);});
    window.requestAnimationFrame=callback=>schedule(now=>{
      const before=performance.now();callback(now);
      if(callback.name==='renderFrame'&&window.__reviewFinalAt!==undefined)window.__reviewFrames.push({
        callbackTime:now-window.__reviewFinalAt,startTime:before-window.__reviewFinalAt,
        renderCost:performance.now()-before,
        alpha:Math.min(1,Math.max(0,(now-window.__reviewFinalAt)/100)),
        actors:window.__arkGardenPreview?.actors.map(actor=>({id:actor.data.id,visible:actor.root.visible,travelled:actor.pose?.travelled,pathLength:actor.path.length,arrived:actor.pose?.arrived})),
      });
    });
  });
  const errors=[],consoleMessages=[];
  page.on('pageerror',error=>errors.push(error.message));
  page.on('console',message=>consoleMessages.push({type:message.type(),text:message.text().slice(0,1500)}));
  await page.route('**/*',route=>/^(file:|data:|blob:)/.test(route.request().url())||localHttp&&new URL(route.request().url()).origin===new URL(url).origin?route.continue():route.abort());
  await page.goto(url);
  try {await page.waitForFunction(()=>!!window.KingdomArkGarden);} catch(error) {
    console.error(JSON.stringify({stage:'module-initialization',errors,consoleMessages},null,2));throw error;
  }
  await page.evaluate(config=>window.KingdomArkGarden.configure({config}),config);
  assert.deepEqual(errors,[]);
  assert.equal(await page.evaluate(()=>window.__arkGardenPreview.actors.length),10);
  if(process.argv.includes('--arrival-draw-guard')) {
    await page.screenshot({path:resolve(output,'garden-postdraw-warmup.png')});
    const taps=Object.fromEntries(config.garden.animals.map(animal=>[animal.id,0]));
    const traffic=new GardenTraffic(config.garden.animals);let finalState;
    while(traffic.tick<config.garden.time_limit_ticks){finalState=traffic.advanceTo(traffic.tick+1,taps);if(finalState.completed)break;}
    assert.equal(finalState.completed,true);
    await page.evaluate(()=>{
      // The owned test response exposes the actual instance without changing
      // the repository's renderer source or its behavior.
      const renderer=window.__reviewActualRenderer;
      if(!renderer)throw new Error('The owned fixture must expose its renderer for this failure injection.');
      window.__reviewOriginalDraw=renderer.render;
      window.__reviewDrawFailures=0;window.__reviewEntered=[];
      renderer.render=function(...args){
        if(window.__arkGardenPreview.actors.every(actor=>actor.pose?.arrived)){
          window.__reviewDrawFailures++;throw new Error('INTENTIONAL_ARK_ARRIVAL_DRAW_FAILURE');
        }
        return window.__reviewOriginalDraw.apply(this,args);
      };
    });
    const completed={...finalState,renderTick:finalState.tick,taps,paused:false,finished:true};
    await page.evaluate(state=>window.KingdomArkGarden.state(state),completed);
    try{await page.waitForFunction(()=>window.__reviewDrawFailures===1,{},{timeout:5000});}catch(error){console.error(JSON.stringify({errors,consoleMessages,probe:await page.evaluate(()=>({hidden:document.hidden,visibility:document.visibilityState,events:window.__reviewEvents,failures:window.__reviewDrawFailures,acknowledgments:window.__reviewEntered,actors:window.__arkGardenPreview.actors.map(actor=>({id:actor.data.id,pose:actor.pose}))}))},null,2));throw error;}
    const failed=await page.evaluate(()=>({arrived:window.__arkGardenPreview.actors.filter(actor=>actor.pose.arrived).length,acknowledgments:window.__reviewEntered.length}));
    assert.deepEqual(failed,{arrived:10,acknowledgments:0},'A failed actual draw must not acknowledge any newly arrived animal');
    await page.evaluate(state=>{
      window.__reviewActualRenderer.render=window.__reviewOriginalDraw;
      window.KingdomArkGarden.state(state);
    },completed);
    await page.waitForFunction(()=>window.__reviewEntered.length===10,{},{timeout:5000});
    await page.evaluate(state=>window.KingdomArkGarden.state(state),completed);
    await page.waitForTimeout(200);
    const enteredEvents=await page.evaluate(()=>window.__reviewEntered);
    assert.deepEqual(enteredEvents.map(event=>event.id).sort(),config.garden.animals.map(animal=>animal.id).sort());
    assert.ok(enteredEvents.every(event=>event.visualOnly===true));
    assert.deepEqual(errors,['INTENTIONAL_ARK_ARRIVAL_DRAW_FAILURE'],'Only the deliberately injected draw error is expected');
    await page.evaluate(()=>window.KingdomArkGarden.dispose());
    const report={scope:'actual renderer post-draw arrival acknowledgment regression',failedDraw:failed,successfulDrawAcknowledgments:enteredEvents,expectedInjectedErrors:errors,unexpectedErrors:[],passed:true};
    await writeFile(resolve(output,'garden-postdraw-arrival-review.json'),JSON.stringify(report,null,2));
    console.log(JSON.stringify(report,null,2));
  }else {
  await page.waitForTimeout(150);
  await page.screenshot({path:resolve(output,'garden-initial.png')});
  const fixedBefore=await page.evaluate(()=>window.__arkGardenPreview.fixedModels.map(model=>model.matrixWorld.toArray()));
  await page.mouse.move(600,220);await page.mouse.down();await page.mouse.move(240,220,{steps:8});await page.mouse.up();
  await page.waitForTimeout(150);
  await page.screenshot({path:resolve(output,'garden-panned-right.png')});
  assert.deepEqual(await page.evaluate(()=>window.__arkGardenPreview.fixedModels.map(model=>model.matrixWorld.toArray())),fixedBefore,'Swiping must not move the Ark or Noah.');
  await page.mouse.move(240,220);await page.mouse.down();await page.mouse.move(600,220,{steps:8});await page.mouse.up();
  const tapEvidence=[];
  await page.evaluate(()=>{window.__reviewTaps=[];window.addEventListener('kingdom-ark-event',event=>{if(event.detail.type==='animalTapped')window.__reviewTaps.push(event.detail.id);});});
  for(const animal of config.garden.animals) {
    await page.evaluate(()=>window.KingdomArkGarden.state({tick:0,renderTick:0,taps:{},paused:false}));
    let target=await page.evaluate(id=>{
      const preview=window.__arkGardenPreview,actor=preview.actors.find(actor=>actor.data.id===id);
      const point=actor.root.position.clone();point.y+=actor.data.height_units/2;point.project(preview.camera);
      return {x:(point.x+1)*844/2,y:(1-point.y)*390/2};
    },animal.id);
    // Exercise the same pointer panning and raycast code used on the phone.
    if(target.x<80||target.x>764) {
      await page.mouse.move(422,180);await page.mouse.down();await page.mouse.move(422+Math.max(-350,Math.min(350,422-target.x)),180,{steps:8});await page.mouse.up();
      await page.waitForTimeout(150);
      target=await page.evaluate(id=>{
        const preview=window.__arkGardenPreview,actor=preview.actors.find(actor=>actor.data.id===id);
        const point=actor.root.position.clone();point.y+=actor.data.height_units/2;point.project(preview.camera);
        return {x:(point.x+1)*844/2,y:(1-point.y)*390/2};
      },animal.id);
    }
    assert.ok(target.x>=0&&target.x<=844&&target.y>=0&&target.y<=390,animal.id+' must be reachable after pan');
    await page.mouse.click(target.x,target.y);
    const selected=await page.evaluate(()=>window.__reviewTaps.at(-1));
    assert.equal(selected,animal.id,animal.id+' projected touch must select that animal after pan');
    tapEvidence.push({id:animal.id,...target});
  }
  await page.evaluate(()=>document.querySelector('#center').click());
  await page.evaluate(()=>window.KingdomArkGarden.replay());
  const taps={elephant:0};
  const traffic=new GardenTraffic(config.garden.animals);
  for(const [label,phase] of [['approach','approach'],['stairs','stairs'],['door','door'],['inside','interior']]) {
    let snapshot;
    while(traffic.tick<config.garden.time_limit_ticks) {
      snapshot=traffic.advanceTo(traffic.tick+1,taps);
      const elephant=traffic.states.find(state=>state.animal.id==='elephant');
      if(phase==='approach'?elephant.distance>7:elephant.frame.phase===phase)break;
    }
    await page.evaluate(state=>window.KingdomArkGarden.state(state),{...snapshot,renderTick:snapshot.tick,taps,paused:false});
    await page.waitForTimeout(150);await page.screenshot({path:resolve(output,`elephant-${label}.png`)});
  }
  const allTaps=Object.fromEntries(config.garden.animals.map(animal=>[animal.id,0]));
  const all=new GardenTraffic(config.garden.animals);let snapshot;
  while(all.tick<config.garden.time_limit_ticks){snapshot=all.advanceTo(all.tick+1,allTaps);if(snapshot.completed)break;}
  assert.equal(snapshot.completed,true);
  await page.evaluate(state=>{window.__reviewFinalAt=performance.now();window.KingdomArkGarden.state(state);},{...snapshot,renderTick:snapshot.tick,taps:allTaps,paused:false,finished:true});
  try {await page.waitForFunction(()=>window.__arkGardenPreview.actors.every(actor=>!actor.root.visible),{},{timeout:5000});}catch(error){
    console.error(JSON.stringify({stage:'final-arrival',frames:await page.evaluate(()=>window.__reviewFrames),actors:await page.evaluate(()=>window.__arkGardenPreview.actors.map(actor=>({id:actor.data.id,pose:actor.pose}))),snapshot},null,2));throw error;
  }
  assert.equal(await page.evaluate(()=>window.__arkGardenPreview.actors.filter(actor=>actor.root.visible).length),0);
  const enteredEvents=await page.evaluate(()=>window.__reviewEntered);
  assert.deepEqual(enteredEvents.map(event=>event.id).sort(),config.garden.animals.map(animal=>animal.id).sort(),'Every saved animal must emit its visual arrival acknowledgment');
  assert.ok(enteredEvents.every(event=>event.visualOnly===true));
  await page.screenshot({path:resolve(output,'garden-complete.png')});
  const finalFrames=await page.evaluate(()=>window.__reviewFrames);
  await page.evaluate(()=>delete window.__reviewFinalAt);
  assert.deepEqual(errors,[]);
  const gaitEvidence=[];
  const localBoneEvidence=[];
  for(const animal of config.garden.animals) {
    await page.evaluate(()=>window.KingdomArkGarden.replay());
    const duration=await page.evaluate(id=>window.__arkGardenPreview.actors.find(actor=>actor.data.id===id).actions.walk.getClip().duration,animal.id);
    const boneSamples=[];
    for(const distance of [0,animal.speed_units_per_second*duration*.35]) {
      const tick=Math.ceil(distance/animal.speed_units_per_second*10);
      const distances=Object.fromEntries(config.garden.animals.map(candidate=>[candidate.id,candidate.id===animal.id?distance:0]));
      await page.evaluate(state=>window.KingdomArkGarden.state(state),{tick,renderTick:tick,taps:{[animal.id]:0},distances,paused:false});
      await page.waitForTimeout(200);
      await page.waitForFunction(({id,distance})=>Math.abs(window.__arkGardenPreview.actors.find(actor=>actor.data.id===id).pose.travelled-distance)<1e-6,{id:animal.id,distance},{timeout:5000});
      boneSamples.push(await page.evaluate(id=>{
        const actor=window.__arkGardenPreview.actors.find(actor=>actor.data.id===id),bones=[];
        actor.root.traverse(object=>{if(object.isBone)bones.push({name:object.name,matrix:object.matrix.toArray()});});
        return {time:actor.actions.walk.time,bones};
      },animal.id));
    }
    const changed=boneSamples[0].bones.filter((bone,index)=>bone.matrix.some((value,element)=>Math.abs(value-boneSamples[1].bones[index].matrix[element])>1e-6)).map(bone=>bone.name);
    assert.ok(changed.length>0,animal.id+' native bone-local animation must change independently of root route motion');
    localBoneEvidence.push({id:animal.id,clipDuration:duration,sampleTimes:boneSamples.map(sample=>sample.time),changedBoneNames:changed});
  }
  await writeFile(resolve(output,'garden-native-gait-render-review.json'),JSON.stringify(localBoneEvidence,null,2));
  for(const animal of process.argv.includes('--quick')?[]:config.garden.animals) {
    await page.evaluate(()=>window.KingdomArkGarden.replay());
    const probes=await page.evaluate(id=>{
      const actor=window.__arkGardenPreview.actors.find(actor=>actor.data.id===id);
      let turn={distance:0,curvature:0};
      for(let distance=0;distance<actor.path.approachLength;distance+=.1){const curvature=actor.path.sample(distance).curvature;if(Math.abs(curvature)>Math.abs(turn.curvature))turn={distance,curvature};}
      return {turn,stairs:actor.path.lines.find(line=>line.phase==='stairs'),door:actor.path.lines.find(line=>line.phase==='door'),duration:actor.actions.walk.getClip().duration};
    },animal.id);
    const snapshots=[];
    for(const [label,distance] of [['turn',probes.turn.distance],['stairs',probes.stairs.start+probes.stairs.length*.5],['door',probes.door.start+probes.door.length*.5]]) {
      const distances=Object.fromEntries(config.garden.animals.map(candidate=>[candidate.id,candidate.id===animal.id?distance:0]));
      const tick=Math.ceil(distance/animal.speed_units_per_second*10);
      await page.evaluate(state=>window.KingdomArkGarden.state(state),{tick,renderTick:tick,taps:{[animal.id]:0},distances,paused:false});
      await page.waitForFunction(({id,distance})=>Math.abs(window.__arkGardenPreview.actors.find(actor=>actor.data.id===id).pose.travelled-distance)<1e-6,{id:animal.id,distance},{timeout:5000});
      await page.screenshot({path:resolve(output,`${animal.id}-${label}-review.png`)});
      snapshots.push(await page.evaluate(id=>{
        const actor=window.__arkGardenPreview.actors.find(actor=>actor.data.id===id);
        const bones=[];actor.root.traverse(object=>{if(object.isBone)bones.push(...object.matrix.elements);});
        return {phase:actor.pose.phase,heading:actor.pose.heading,curvature:actor.pose.curvature,gaitWeights:{...actor.gait.weights},animationTime:actor.actions.walk.time,bones};
      },animal.id));
    }
    assert.ok(snapshots[0].bones.some((value,index)=>Math.abs(value-snapshots[1].bones[index])>1e-6),animal.id+' must show native skeleton movement between gait samples');
    gaitEvidence.push({id:animal.id,turn:probes.turn,samples:snapshots.map(({bones,...sample})=>sample),nativeSkeletonChanges:true});
  }
  if(gaitEvidence.length)await writeFile(resolve(output,'garden-gait-visual-review.json'),JSON.stringify(gaitEvidence,null,2));
  await page.evaluate(()=>window.KingdomArkGarden.dispose());
  const report={scope:'actual renderer in isolated software-WebGL test; no Safari/phone activation',screenshots:output,animals:10,staticModelsPreserved:true,complete:true,tapEvidence,enteredEvents,gaitEvidence,localBoneEvidence,finalFrames,errors};
  await writeFile(resolve(output,process.argv.includes('--quick')?'garden-renderer-arrival-review.json':'garden-renderer-review.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
  }
}finally {
  await browser?.close();
  if(server)await new Promise(resolve=>server.close(resolve));
  await rm(fixture,{force:true});
}
