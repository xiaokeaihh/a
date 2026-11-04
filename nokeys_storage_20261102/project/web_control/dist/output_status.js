'use strict';
// The tracking preview shows only the sampled image, without a copied status
// patch over its lower-right pixels. Keep the node for existing UI bindings.
(()=>{
 const badge=document.getElementById('followStatus'),video=document.getElementById('video'),image=document.getElementById('personVideo');
 if(!badge)return;
 const context=badge.getContext('2d');
 function update(){
  badge.hidden=true;context.clearRect(0,0,badge.width,badge.height);
 }
 setInterval(update,100);video.addEventListener('loadeddata',update);
})();
