# ddtrace `--ini=diff` orig_value corruption / SIGSEGV — investigation summary

調査メモ。standalone な再現 repo を作るための材料として、ここまでに確かめたことを記録。

## 1. TL;DR

- **本体バグ**: `ddtrace` 拡張は `datadog.*` の INI ディレクティブを「壊れた `orig_value` ポインタ」で登録している。すべての `datadog.*` ディレクティブが**同じ 1 個のダングリング/未初期化のポインタ**を `orig_value` として共有している。
- **可視化された経路**: PHP 8.5 で導入された `php --ini=diff` が、各 INI ディレクティブの `orig_value` を `%s` で印字するため、この壊れたポインタの中身が出力に現れる（文字化け）。それ以前の PHP では誰も `orig_value` を全件読みにいくコードパスを通らなかったので潜在化していた。
- **症状**:
  1. **データ corruption（universal）**: `--ini=diff` が `datadog.* : "<壊れた文字列>" -> "<実値>"` を出す。`php -n -d extension=ddtrace.so --ini=diff` の 1 行だけで観測可能。
  2. **SIGSEGV（メモリレイアウト依存）**: 壊れたポインタが unmapped 域を指すレイアウトになると `php_printf` / `php_printf_to_smart_string` で SEGV。当環境では `ddtrace + 任意の追加 .so 1 個` を `php.ini` 経由でロードすると 100% 再現。
- **修正位置**: upstream ddtrace（https://github.com/DataDog/dd-trace-php）。INI 登録時に `orig_value` を string literal もしくは永続バッファで保持するよう直せば両方消える。

## 2. 確認環境

- PHP 8.5.5 (`php:8.5-cli` ベースの colopl/docker-php image)
- ddtrace 拡張: `/opt/datadog-php/extensions/ddtrace-20250925.so` (Datadog 公式インストーラ由来)
- aarch64 (Apple Silicon, OrbStack)
- `php --ini=diff` は PHP 8.5 で追加された新 CLI フラグ。8.4 以前にはこのコードパスは無い。

## 3. データ corruption の証拠

`-n` で全 `php.ini` を無効化し、`-d extension=...` で ddtrace のみロードするだけでも、全 `datadog.*` の `orig_value` が文字化けで出る。

```sh
$ php -n -d extension=/opt/datadog-php/extensions/ddtrace-20250925.so --ini=diff
Non-default INI settings:
datadog.agent_host: "�K����" -> "localhost"
datadog.amqp_analytics_enabled: "�K����" -> "0"
datadog.amqp_analytics_sample_rate: "�K����" -> "1.0"
datadog.api_key: "�K����" -> ""
datadog.apm_tracing_enabled: "�K����" -> "true"
...
```

ポイント:

- すべての `datadog.*` の "default" 列が **同一の 1 個の壊れたポインタ**を参照している（毎回同じ文字列が出る）。これは ddtrace の INI 登録ループが `orig_value` フィールドに「同一の一時バッファ/スタック領域のアドレス」を全エントリに格納してしまっていることを強く示唆。
- 別プロセスで実行すると毎回違う文字化けが出る（ASLR 由来）。同一プロセス内では同一の garbage。

## 4. SIGSEGV としての発現条件（n=100 で計測）

| config | 壊れた orig_value の印字 | SIGSEGV 率 |
|---|---|---|
| `php -n -d extension=ddtrace.so --ini=diff` | あり | 0/100 |
| `php -n -d extension=pcov -d extension=ddtrace.so --ini=diff` | あり | 0/100 |
| `php -d extension=pcov -d extension=ddtrace.so --ini=diff`（php.ini あり） | あり | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff`（ddtrace.ini のみ） | あり | 0/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff`（grpc.ini + ddtrace.ini） | あり | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff`（xdebug.ini + ddtrace.ini） | あり | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff`（pcov.ini + ddtrace.ini） | あり | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff`（colopl_bc.ini + ddtrace.ini） | あり | 0/100 |

読み取れること:

- ddtrace 単独 では SEGV しない（壊れた orig_value は readable な garbage 域に乗っている）
- ddtrace に「もう 1 個 .so をロードする」「`php.ini` を読む」のいずれかでメモリレイアウトが変わり、壊れた orig_value が unmapped 域へ移動 → 100% SEGV
- 100% を出した同居 .so: `grpc`、`xdebug`、`pcov`。**`pcov` がビルド最軽量**（数秒）なので upstream 再現用にはこれが最適。
- `colopl_bc` だけ 0%（偶然 readable 域に乗ったまま）

## 5. gdb backtrace（SEGV 時）

`php --ini=diff` が落ちるときのスタック（symbol なしビルドなので `??` だらけだが、PHP 関数名は得られる）:

```
#0  in libc.so.6                              # おそらく __strlen / memcpy on bad pointer
#1  ??                                        # SAPI cli display_ini_entries_diff 内
#2  php_printf_to_smart_string ()
#3  zend_vspprintf ()
#4  php_printf ()
#5  ??                                        # SAPI cli の diff 出力ループ
#6  ??                                        # main
#7  __libc_start_main () from libc.so.6
#8  _start ()
```

`php_printf("...%s...", entry->orig_value, ...)` で `orig_value` が未マップ番地 → libc の文字列処理で SEGV、という標準的なパターン。

## 6. 上流バグの所在（仮説）

`Zend/zend_ini.c` 系の API は INI 登録時に `orig_value` を内部でコピーして保持する動作になっているはず。なので、ddtrace 側のコードで以下のいずれかが起きていると推定:

- ddtrace が独自に `zend_ini_entry` 構造体を組み立てて hash に直接挿入していて、`orig_value` をスタック上の一時バッファのアドレスにしている
- もしくは登録直後に解放される heap バッファのアドレスをそのまま入れている
- もしくは `orig_value` を初期化していない（malloc 直後のごみが残っている）

dd-trace-php のソースで `orig_value` または `ini_entry` を直接組み立てている箇所を grep するのが最初の一歩。

## 7. 上流に投げるときの最小再現案

### 6.1 cmdline ワンライナー（データ corruption の証拠）

```sh
php -n -d extension=/path/to/ddtrace.so --ini=diff
```

→ `datadog.* : "<garbage>" -> "<value>"` の連発。1 行 + ddtrace.so 1 個だけ。

### 6.2 SIGSEGV 確実再現（symptom の重さの証拠）

```sh
# php:8.5-cli + pcov + ddtrace
docker run --rm -v /opt/datadog-php:/opt/datadog-php php:8.5-cli sh -c '
  apt-get update -qq && apt-get install -y --no-install-recommends $PHPIZE_DEPS >/dev/null
  pecl install pcov >/dev/null 2>&1
  docker-php-ext-enable pcov
  echo "extension=/opt/datadog-php/extensions/ddtrace-XXXXXXXX.so" \
    > /usr/local/etc/php/conf.d/zz-ddtrace.ini
  for i in $(seq 1 100); do
    php --ini=diff >/dev/null 2>&1; echo $?
  done | sort | uniq -c
'
```

→ `139` (SEGV) が 100 回出る想定。

注: `-v /opt/datadog-php:/opt/datadog-php` の代わりに、Datadog 公式インストーラを container 内で走らせれば、外部マウント不要で完結する。

## 8. オープンクエスチョン（再現 repo を組むときに片付けたい）

- [ ] stock な `php:8.5-cli` + Datadog 公式インストーラ + pcov の組み合わせで本当に 100% SEGV が出るか（colopl-baked image 依存ではないか）
- [ ] amd64 でも同様の率で再現するか
- [ ] PHP 8.5.0 / 8.5.1 / 8.5.5 で挙動が変わるか（5 はうちの環境）
- [ ] ddtrace の他バージョン（e.g. 1.5、1.10、最新）で再現するか — 何バージョンから/まで影響するか
- [ ] 壊れた orig_value がどこに由来するのか、ddtrace ソースを `grep -r 'orig_value\|REGISTER_INI_ENTRIES'` で当てる

## 9. 当面の運用回避

- `php --ini=diff` を呼ばない（CLI ユーザの教育のみで運用回避可能）
- どうしても呼ぶ必要があるなら、`-n -d extension=...` で必要拡張を絞り、ddtrace を含めない
- `ddtrace.disable=1` は **効かない**（拡張は load されるので INI 登録は走る）
