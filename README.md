# YerAnotherMangaReader

PDFを漫画のページ順に見開き表示するリーダー

ウィンドウサイズに合わせて適当に拡大縮小する

## 要件

- ruby 1.9 のみ対応(1.8ではテストしてない)
- glib2, pango, gtk2, atk, cairo, gdk_pixbuf2, poppler に依存

先行して数字を入力するとカウント付きになります。

## キーバインド

- j: 2ページ進む
- k: 2ページ戻る
- H: 左側ページに空白ページを挿入
- L: 右側ページに空白ページを挿入
- b: 見開きのずれを修正するかも
- g: 最初のページに戻る
- v: 左右逆にする
- s: 見開き/単ページを切り替える
- q: 終了すする

## キーバインド - count 付き

以下のキーに先行して、数値キーの入力があると、その数だけ count が付きます。

- j: nページ進む
- k: nページ戻る
- g: nページ目を表示
- s: nページ同時に表示する(10ページまで)

## 状態保持機能

$HOME/.yamr.saves にファイルごとの状態を保持します。


## rc ファイル

```ruby
on_open {
  |doc|
  if doc.loaded
  else
    doc.insert_blank_page_to_left
  end
  if /magazine/ === doc.filepath.to_s
    doc.invert
  end
}

```
