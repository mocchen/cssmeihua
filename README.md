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

<!--引入Alist的css样式-->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/mocchen/cssmeihua/css/alistcss.css" />
```
### 自定义内容
```shell
<!DOCTYPE html>
<html>
<head>
    <style>
        #customize {
            position: fixed;
            bottom: 0;
            left: 0;
            background-color: transparent; /* 背景透明 */
            color: #fff;
            padding: 10px;
        }
        
        #hitokoto {
            color: #ffffff;
            font-weight: bold;
        }
    </style>
</head>
    <!-- 一言 API 部分放在左下角 -->
    <div id="customize">
        <span>
            "<span id="hitokoto">
                <a href="#" id="hitokoto_text">
                    "人间烟火气，最抚凡人心."
                </a>
            </span>"
        </span>
        <p style="font-size: 8pt;">
            <small>
                —— Mochen
            </small>
        </p>
    </div>
    <!-- 一言 API -->
    <script src="https://v1.hitokoto.cn/?encode=js&select=%23hitokoto" defer></script>
</body>
</html>

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
```
