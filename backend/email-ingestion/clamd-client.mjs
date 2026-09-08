import net from 'node:net';

function command(host,port,name,payload){
  return new Promise((resolve,reject)=>{
    const socket=net.createConnection({host,port}),chunks=[];
    socket.setTimeout(30000);socket.on('error',reject);socket.on('timeout',()=>socket.destroy(new Error('clamd timeout')));
    socket.on('data',chunk=>chunks.push(chunk));socket.on('end',()=>resolve(Buffer.concat(chunks).toString('utf8').replace(/\0$/,'').trim()));
    socket.on('connect',()=>{socket.write(`z${name}\0`);if(payload){for(let offset=0;offset<payload.length;offset+=64*1024){const chunk=payload.subarray(offset,offset+64*1024),size=Buffer.alloc(4);size.writeUInt32BE(chunk.length);socket.write(size);socket.write(chunk)}socket.end(Buffer.alloc(4))}});
  });
}
export const scannerVersion=(host,port)=>command(host,port,'VERSION');
export async function scanBuffer(host,port,bytes){const response=await command(host,port,'INSTREAM',bytes);if(response.endsWith(': OK'))return {clean:true,response};if(response.endsWith(' FOUND'))return {clean:false,response};throw new Error(`scanner failure: ${response}`)}
export function assertFresh(version,maxAgeHours=72){const parts=version.split('/'),date=new Date(parts.slice(2).join('/').trim()),age=Date.now()-date.valueOf();if(parts.length<3||Number.isNaN(date.valueOf())||age<0||age>maxAgeHours*3600000)throw new Error('scanner signatures stale')}
