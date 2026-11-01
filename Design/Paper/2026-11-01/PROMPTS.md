# 纸张背景生成记录

唯一资源原图位于 `Sources/ReadingBook/Resources/Paper/`，此处不重复保留一套大图。

使用 imagegen 内置工具，2026-11-01。用户选择三种均保留，默认原始白纸。每张实际输出为 1536 × 1024 PNG；提示词中的“4K quality”是生成期望，不等于实际 4K 输出。

共同要求：整幅无文字的平面纸张扫描，柔和均匀光照；无边缘、折痕、阴影、透视、古旧污渍或大颗粒；只保留低对比的细纤维和磨砂纸感，适合叠加密集黑色正文。

- warm-cotton.png：暖白棉纸，浅中性奶油色 #f3eee4，未涂布细纤维。
- mist-white.png：雾白纸，近中性的浅灰白 #efefea，细微哑光纹理。
- sage-paper.png：淡鼠尾草纸，极浅低饱和灰绿 #e9eee5，均匀纤维纹理。

完整共同提示：Use case: photorealistic-natural. Asset type: full-screen high-resolution reading-paper background texture for a macOS book reader. Flat scan of one blank sheet filling the ENTIRE frame, 4K landscape quality. Edge-to-edge material only. The entire surface must remain nearly uniform and quiet behind dense black text, texture contrast no more than 2 percent. Soft even diffuse lighting, no directional illumination. No text, no letters, no objects, no page borders, no folds, no edges, no perspective, no vignette, no shadows, no dark corners, no yellow antique stains, no large speckles, no visible repetitive pattern. High-resolution realistic microscopic paper, not an illustration. Output only the blank texture.
