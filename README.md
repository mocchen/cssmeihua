# 网页美化

## 探针美化
```shell
<!-- 引入css -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/css/nezhacss.css">

<!-- 底部 -->
<script src="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/nezhajs.js"></script>

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
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/css/alistcss.css" />
```
### 自定义内容
```shell
<div id="customize">
    <div>
        <br />
        <center class="dibu">
            <div style="line-height: 20px; font-size: 9pt; font-weight: bold;">
                <span>
                    "
                    <span style="color: rgb(255, 255, 255); font-weight: bold;" id="hitokoto">
                        <a href="#" id="hitokoto_text">
                            "人间烟火气，最抚凡人心."
                        </a>
                    </span> "
                </span>
                <p style="margin-left: 10rem; font-size: 8pt;">
                    <small>
                        —— Mochen
                    </small>
                </p>
            </div>
        </center>
        <br />
        <br />
    </div>
    <!--一言API-->
    <script src="https://v1.hitokoto.cn/?encode=js&select=%23hitokoto" defer></script>
</div>

```
