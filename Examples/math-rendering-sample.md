# 数学公式与排版验收

这篇原创示例用于检查阅读、笔记预览和保存回答时的公式排版。

## 行内与块公式

设 $f(x)=e^{-x^2}$，其导数为 \(f'(x)=-2xe^{-x^2}\)。中文与公式应自然连接。

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx=\sqrt{\pi},\qquad
\sum_{n=1}^{\infty}\frac{1}{n^2}=\frac{\pi^2}{6}.
$$

\[
\lim_{n\to\infty}\left(1+\frac{x}{n}\right)^n=e^x
\]

## 矩阵、分段与多行推导

$$
A=\begin{pmatrix}1&2\\3&4\end{pmatrix},\qquad
|x|=\begin{cases}x,&x\ge 0,\\-x,&x<0.\end{cases}
$$

\begin{align}
(a+b)^2 &= a^2+2ab+b^2 \\
(a-b)^2 &= a^2-2ab+b^2
\end{align}

$$
\begin{aligned}
\nabla\cdot\mathbf{E}&=\frac{\rho}{\varepsilon_0}, &
\nabla\cdot\mathbf{B}&=0,\\
\nabla\times\mathbf{E}&=-\frac{\partial\mathbf{B}}{\partial t}, &
\nabla\times\mathbf{B}&=\mu_0\mathbf{J}+\mu_0\varepsilon_0\frac{\partial\mathbf{E}}{\partial t}.
\end{aligned}
$$

## 表格与代码

| 对象 | 表达式 | 含义 |
| :--- | :---: | :--- |
| 导数 | $f'(x)$ | 变化率 |
| 范数 | $\lVert x\rVert_2$ | 欧氏长度 |

> 拖动窗口变窄时，表格和长公式可以横向滚动，正文不应撑大整个窗口。

代码中的 `$x$` 与 `\begin{align}` 应保留原样。

```latex
\frac{a}{b}  % 代码区不执行公式渲染
$$not math inside code$$
```

## 自己的理解

- [ ] 在阅读页检查公式。
- [ ] 点击“记一笔”，保存为 Markdown。
- [ ] 进入预览，缩放窗口检查排版。
- [ ] 在导图里单击选中、拖动位置，再双击打开内容。
