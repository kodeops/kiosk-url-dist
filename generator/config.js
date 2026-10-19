/* Versioned JSON configuration shared by downloads, imports and local storage. */
function makeConfiguration(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || (input.version !== undefined && input.version !== 1)) throw Error('Configuration version must be 1.');
  const browser=input.browser??'google-chrome', delay=input.delay??0, disabled=input.disabled??[], flags=input.flags??[];
  if (typeof browser!=='string'|| !/^[A-Za-z0-9._/-]+$/.test(browser)) throw Error('Invalid browser executable.');
  if (typeof delay!=='number'||!Number.isFinite(delay)||delay<0||delay>60) throw Error('Delay must be between 0 and 60 seconds.');
  const validOutput=x=>typeof x==='string'&&/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(x);
  if (!Array.isArray(disabled)||!disabled.every(validOutput)) throw Error('Invalid disabled outputs.');
  if (!Array.isArray(flags)||!flags.every(x=>typeof x==='string'&&x.startsWith('--')&&!x.includes('\0'))) throw Error('Flags must be an array of Chrome --options.');
  if (flags.some(x=>/^(--user-data-dir|--remote-debugging|--window-|--app|--class|--headless|--kiosk|--start-fullscreen)/.test(x))) throw Error('Flags cannot override profile, diagnostics or window placement.');
  if (!Array.isArray(input.screens)||input.screens.length<1) throw Error('Configure at least one display.');
  const outputs=new Set();
  const screens=input.screens.map((s,i)=>{
    if (!s||typeof s!=='object'||Array.isArray(s)||(s.on!==undefined&&typeof s.on!=='boolean')) throw Error('Invalid display object.');
    const screen={name:s.name??'Display '+(i+1),out:s.out,res:s.res,hz:s.hz??60,rot:s.rot??'normal',url:s.url,on:s.on??true};
    if (!screen.on) return screen;
    if (!validOutput(screen.out)||outputs.has(screen.out)||disabled.includes(screen.out)) throw Error('Enabled outputs must be valid, unique and not disabled.');
    outputs.add(screen.out);
    if (typeof screen.res!=='string'||!/^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$/.test(screen.res)) throw Error('Invalid display resolution.');
    if (!['normal','left','right','inverted'].includes(screen.rot)) throw Error('Invalid display rotation.');
    if (!['number','string'].includes(typeof screen.hz)||!/^\d+(?:\.\d+)?$/.test(String(screen.hz))||Number(screen.hz)<1||Number(screen.hz)>240) throw Error('Refresh rate must be between 1 and 240 Hz.');
    if (typeof screen.url!=='string'||!/^https?:\/\/[^\s/]+/.test(screen.url)||/[\x00-\x1f]/.test(screen.url)) throw Error('Display URLs must use http:// or https://.');
    if (typeof screen.name!=='string'||!screen.name.trim()||/[\x00-\x1f]/.test(screen.name)) throw Error('Display names must be nonempty single-line strings.');
    return screen;
  });
  if (!screens.some(s=>s.on)) throw Error('Enable at least one display.');
  const primary=input.primary??screens.find(s=>s.on).out;
  if (typeof primary!=='string'||!outputs.has(primary)) throw Error('Primary display must reference an enabled output.');
  return {version:1,browser,delay,disabled,flags,primary,screens};
}
