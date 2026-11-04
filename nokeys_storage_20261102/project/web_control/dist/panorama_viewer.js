'use strict';
// Cylindrical texture -> rectilinear virtual camera. Rendering is independent
// of stitching/upload cadence, with no network request on pointer movement.
window.WYCPanoramaViewer=class {
 constructor(canvas,onchange=()=>{}){
  this.canvas=canvas;this.onchange=onchange;this.yaw=0;this.pitch=0;this.fov=90;this.ready=false;
  const gl=this.gl=canvas.getContext('webgl',{alpha:false,antialias:false});
  if(!gl)throw Error('当前浏览器无法开启全景视角，请启用硬件加速');
  const shader=(type,code)=>{const s=gl.createShader(type);gl.shaderSource(s,code);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;};
  const p=this.program=gl.createProgram();
  gl.attachShader(p,shader(gl.VERTEX_SHADER,'attribute vec2 p;varying vec2 uv;void main(){uv=p*.5+.5;gl_Position=vec4(p,0.,1.);}'));
  gl.attachShader(p,shader(gl.FRAGMENT_SHADER,`precision highp float;varying vec2 uv;uniform sampler2D pano;uniform vec4 camera;uniform vec2 shape;
   void main(){float t=tan(camera.z*.5);vec3 r=normalize(vec3((uv.x-.5)*2.*t,(.5-uv.y)*2.*t/camera.w,1.));
    float cp=cos(camera.y),sp=sin(camera.y);r=vec3(r.x,cp*r.y-sp*r.z,sp*r.y+cp*r.z);
    float cy=cos(camera.x),sy=sin(camera.x);r=vec3(cy*r.x+sy*r.z,r.y,-sy*r.x+cy*r.z);
    vec2 q=vec2(atan(r.x,r.z)/6.28318530718+.5,.5-r.y/max(.00001,length(r.xz))*shape.x/shape.y/6.28318530718);
    if(q.y<0.||q.y>1.)gl_FragColor=vec4(0.,0.,0.,1.);else gl_FragColor=texture2D(pano,vec2(fract(q.x),q.y));}`));
  gl.linkProgram(p);if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(p));gl.useProgram(p);
  const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);
  const loc=gl.getAttribLocation(p,'p');gl.enableVertexAttribArray(loc);gl.vertexAttribPointer(loc,2,gl.FLOAT,false,0,0);
  this.texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,this.texture);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
  canvas.addEventListener('pointerdown',e=>{canvas.setPointerCapture(e.pointerId);this.drag={x:e.clientX,y:e.clientY,yaw:this.yaw,pitch:this.pitch};});
  canvas.addEventListener('pointermove',e=>{if(!this.drag)return;const d=this.drag;this.set(d.yaw-(e.clientX-d.x)*this.fov/canvas.clientWidth,d.pitch+(e.clientY-d.y)*this.fov/canvas.clientWidth);});
  for(const type of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(type,()=>this.drag=null);
  canvas.addEventListener('wheel',e=>{e.preventDefault();this.fov=Math.max(45,Math.min(110,this.fov+Math.sign(e.deltaY)*4));this.render();},{passive:false});
 }
 set(yaw,pitch=this.pitch){this.yaw=((yaw+540)%360)-180;this.pitch=Math.max(-35,Math.min(35,pitch));this.render();}
 image(image){const gl=this.gl;gl.bindTexture(gl.TEXTURE_2D,this.texture);gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGB,gl.RGB,gl.UNSIGNED_BYTE,image);this.width=image.naturalWidth||image.width;this.height=image.naturalHeight||image.height;this.ready=true;this.render();}
 render(){if(!this.ready)return;const gl=this.gl,p=this.program;gl.useProgram(p);gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.uniform4f(gl.getUniformLocation(p,'camera'),this.yaw*Math.PI/180,this.pitch*Math.PI/180,this.fov*Math.PI/180,this.canvas.width/this.canvas.height);gl.uniform2f(gl.getUniformLocation(p,'shape'),this.width,this.height);gl.drawArrays(gl.TRIANGLE_STRIP,0,4);this.onchange(this);}
};
