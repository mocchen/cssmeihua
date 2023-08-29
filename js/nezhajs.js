<!--Logo和版权-->
<script>
window.onload = function(){
var avatar=document.querySelector(".item img")
var footer=document.querySelector("div.is-size-7")
footer.innerHTML="末晨的探针"
footer.style.visibility="visible"
avatar.src="https://blog.mochen.one/upload/2022/11/%E4%B8%8B%E8%BD%BD.webp"
avatar.style.visibility="visible"
}
var faviconurl="https://blog.mochen.one/upload/2022/11/%E4%B8%8B%E8%BD%BD.webp" ;                  
var link = document.querySelector("link[rel*='icon']") || document.createElement('link');
link.type = 'image/x-icon';
link.rel = 'shortcut icon';
link.href = faviconurl;
document.getElementsByTagName('head')[0].appendChild(link);
</script>
