# 网页美化

## 探针美化
```shell
<!-- 引入css -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/css/nezhacss.css">

<!-- 底部 -->
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/nezha.js"></script>

<!-- 网页特效 - 樱花 -->
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/js/yinghua.js"></script>

<!-- 网页鼠标点击特效 - 爱心 -->
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/js/aixin.js"></script>

<!-- 网页鼠标点击特效 - 烟花波纹 -->
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/js/yanhuabowen.js"></script>

<!-- 网页特效 - 蜘蛛网 -->
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/js/zhizhuwang.js"></script>

<!-- 鼠标特效 - 小星星拖尾 -->
<span class="js-cursor-container"></span>
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/js/xiaoxingxing.js"></script>
```
## Alist美化
### 自定义头部
```shell
<!--Alist V3建议添加的，已经默认添加了，如果你的没有建议加上-->
<script src="https://polyfill.io/v3/polyfill.min.js?features=String.prototype.replaceAll"></script>

<!--引入字体，全局字体使用-->
<link rel="stylesheet" href="https://npm.elemecdn.com/lxgw-wenkai-webfont@1.1.0/lxgwwenkai-regular.css" />

<!-- Font6，自定义底部使用和看板娘使用的图标和字体文件-->
<link type='text/css' rel="stylesheet" href="https://npm.elemecdn.com/font6pro@6.0.1/css/fontawesome.min.css" media='all'>
<link href="https://npm.elemecdn.com/font6pro@6.0.1/css/all.min.css" rel="stylesheet">

<!--引入Alist的css样式-->
<link rel="stylesheet" href="https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/css/alist.css" />
```
### 自定义内容
```shell
<!--延迟加载-->
<!--如果要写自定义内容建议都加到这个延迟加载的范围内-->
<div id="customize" style="display: none;">
    <div>

        <br />
        <center class="dibu">
            <div style=" line-height: 20px;font-size: 12pt;font-weight: bold;">
                <span>
                    「
                    <span style="color: rgb(250, 126, 35); font-weight: bold;" id="hitokoto">
                        <a href="#" id="hitokoto_text">
                            "人生最大的遗憾，就是在最无能为力的时候遇到一个想要保护一生的人。"
                        </a>
                    </span>」
                </span>
                <p style="margin-left: 10rem;font-size: 8pt;">
                    <small>
                         — — Naruto's Cloud
                    </small>
                </p>
            </div>

            <div style="font-size: 13px; font-weight: bold;">
                <span class="nav-item">
                    <a class="nav-link" href="https://narutos.top" target="_blank">
                        <i class="fa-sharp fa-solid fa-house" style="color:#409EFF;" aria-hidden="true">
                        </i>
                        主页 |
                    </a>
                </span>
                <span class="nav-item">
                    <a class="nav-link" href="https://blog.narutos.top" target="_blank">
                        <i class="fas fa-edit" style="color:#409EFF" aria-hidden="true">
                        </i>
                        博客 |
                    </a>
                </span>
                <span class="nav-item">
                    <a class="nav-link" href="mailto:naruto@narutos.top" target="_blank">
                        <i class="fa-duotone fa-envelope-open" style="color:#409EFF" aria-hidden="true">
                        </i>
                        邮箱 |
                    </a>
                </span>
                <!--后台入口-->
                <span class="nav-item">
                    <a class="nav-link" href="/@manage" target="_blank">
                        <i class="fa-solid fa-folder-gear" style="color:#409EFF;" aria-hidden="true">
                        </i>
                        管理 |
                    </a>
                </span>
                <!--版权，请尊重作者-->
                <span class="nav-item">
                    <a class="nav-link" href="https://github.com/Xhofe/alist" target="_blank">
                        <i class="fa-solid fa-copyright" style="color:#409EFF;" aria-hidden="true">
                        </i>
                        Alist
                    </a>
                </span>
                <br />
            </div>
        </center>
        <br />
        <br />
    </div>

    <!--一言API-->
    <script src="https://v1.hitokoto.cn/?encode=js&select=%23hitokoto" defer></script>
<!--延迟加载范围到这里结束-->
</div>
<!--延迟加载配套使用JS-->
<script>
    let interval = setInterval(() => {
        if (document.querySelector(".footer")) {
            document.querySelector("#customize").style.display = "";
            clearInterval(interval);
        }
    }, 200);
</script>

<!-- 渐变背景初始化，如果要使用渐变背景把下面的那一行注释去掉即可-->
<!-- 就是把 《!--xxx --》删掉-->
<!-- 下面的几行都是渐变的一套,自定义头部内还有一个关联的自定义CSS -->
<!--<canvas id="canvas-basic"></canvas> -->
<script src="https://npm.elemecdn.com/granim@2.0.0/dist/granim.min.js"></script>
<script>
var granimInstance = new Granim({
    element: '#canvas-basic',
    direction: 'left-right',
    isPausedWhenNotInView: true,
    states : {
        "default-state": {
            gradients: [
                ['#a18cd1', '#fbc2eb'],
                 ['#fff1eb', '#ace0f9'],
                 ['#d4fc79', '#96e6a1'],
                 ['#a1c4fd', '#c2e9fb'],
                 ['#a8edea', '#fed6e3'],
                 ['#9890e3', '#b1f4cf'],
                 ['#a1c4fd', '#c2e9fb'],
                 ['#fff1eb', '#ace0f9']
           
            ]
        }
    }
});
</script>

<!-- 网页特效 - 樱花 -->
<script src="https://cdn.jsdelivr.net/gh/2E98514DF5A395297392026440B30569/4610153EC2F4FEF0F14333C127392601/js/yinghua.js"></script>

<!-- 网页鼠标点击特效 - 爱心 -->
<script src="https://cdn.jsdelivr.net/gh/2E98514DF5A395297392026440B30569/4610153EC2F4FEF0F14333C127392601/js/aixin.js"></script>

<!-- 网页鼠标点击特效 - 烟花波纹 -->
<script src="https://cdn.jsdelivr.net/gh/2E98514DF5A395297392026440B30569/4610153EC2F4FEF0F14333C127392601/js/yanhuabowen.js"></script>

<!-- 网页特效 - 蜘蛛网 -->
<script src="https://cdn.jsdelivr.net/gh/2E98514DF5A395297392026440B30569/4610153EC2F4FEF0F14333C127392601/js/zhizhuwang.js"></script>

<!-- 鼠标特效 - 小星星拖尾 -->
<span class="js-cursor-container"></span>
<script src="https://cdn.jsdelivr.net/gh/2E98514DF5A395297392026440B30569/4610153EC2F4FEF0F14333C127392601/js/xiaoxingxing.js"></script>
```
