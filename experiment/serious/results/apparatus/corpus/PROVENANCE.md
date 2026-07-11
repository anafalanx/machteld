# Serious corpus provenance

This corpus is a reproducible, language-neutral projection of all 30
validated tasks in `_tika/experiment/tasks_serious`. The source report is
`_tika/experiment/results/REPORT_serious.md` (2026-06-20).

The importer renames source `word` to neutral `fn`, adds the frozen family
stratum, extracts the embedded Python reference, and removes only wording
that prescribed a source-language or fixed-width implementation technique
irrelevant to both bignum arms. Inputs, outputs,
task behavior, visible cases, and hidden cases are unchanged.
The available `_tika` tree has no VCS metadata, so the recorded relative
paths plus SHA-256 hashes are the authoritative source identity.

## Frozen totals

- 30 tasks; 90 visible cases; 464 hidden cases.
- Of 464 inherited hidden rows, 17 repeat a visible row and 2 repeat another hidden row within the same task, leaving 445 novel unique hidden rows.
- Difficulty: 4 mid, 18 hard, 8 very-hard.
- Family: 12 validator/checksum, 7 number-theory/crypto, 7 bit/encoding/hashing, 4 interpreter/state-machine.

The source report states the stratum totals but not its per-task labels. The
exhaustive mapping in `import_corpus.py` is therefore the prospective frozen
operational mapping for this experiment. It was fixed before subject trials.

## Reproduction

From `C:\dev\_machteld`:

```powershell
C:\dev\z.exe python -I -S -B experiment/serious/import_corpus.py
C:\dev\z.exe python -I -S -B experiment/serious/import_corpus.py --check
```

Importer SHA-256: `40a4fb1c3b5e63628d9ca23f4ffc61483170038dfcc44037813596ae6fc472d8`  
Source report SHA-256: `8a12b6daf12648babeca39745bffb2cb653fba426e8376d1c8809b217ffe7a44`

## Per-task hashes

| Task | Family | Difficulty | Visible | Hidden | Novel hidden | Source SHA-256 | Neutral task SHA-256 | Python ref SHA-256 |
|---|---|---:|---:|---:|---:|---|---|---|
| `bracket_balanced` | validator | hard | 3 | 16 | 13 | `5ed6076baac94f9b54c96be4f08ec7ff38f1585e4b730e11ac6879ef7acc1e7f` | `9726ae5be49e8b52e5b9d4c02e992dd5a87d874f2b109bc9b33e89ac440ccb6b` | `dd4264b47c81e546c22dbc8aed51a0f47707bfe5442dba2fcaa070b39611b810` |
| `collatz_max` | interpreter | hard | 3 | 16 | 13 | `a34c7444042d7e7d3e6947d8a2d2cfe96e07380bbb54b05d91495a8038e0ec6c` | `234d8ba29c8abb312e0bb84f45dc9e69b74620acce6f06aee13c80274d187c7f` | `7898e621982389da7b3c29c345f3e8a4cf93c8e3fcc393eea503dba6bfda2b89` |
| `crt2` | number-theory | very-hard | 3 | 21 | 21 | `a6ed6c980e0ec6fad7a0826b87aa573db7039f3502172c961d7ad5208fda09c4` | `f229e2983d7f48afd0987d6682ca1bd865f2ec074a8659821fdfc5bafbc2563e` | `b5e2bb25bc930ed2d85072eb218482605a6bd82a25b0bed2e4a4fd0743bd7b07` |
| `damm_check` | validator | very-hard | 3 | 15 | 14 | `f365064c500c3f371df6aafb309a78ef227c1b9f34749a58d8e2537e235b92c5` | `b6482f2a9dc1fbed50187230805322b1b3b4f2c8b491b5979f09ff9a807dc110` | `dce541a82412c19ae2229c92c71b437494ddca895bfd39760c2816b12eec72ce` |
| `damm_valid` | validator | very-hard | 3 | 12 | 12 | `0315d660e6e29cb07ef79988b0188bd7f12c544b12e30646e339e8e5d55b144f` | `d9cba5281eb4af0e10514ecbd3ec8455dc7214d9f97028e9ba998ce3d6dc5878` | `5ccd21bcc220d084aa5886a697d93f507aa69168f2a0d5155ff6200e180ac712` |
| `date_valid` | validator | hard | 3 | 16 | 13 | `bed7ee2054a4e0f0c7918a8aea535ec89b41eae80ca95c66cf9367b7aced8484` | `a95f436f166e0f80aa3209430812f93913bab32ffb27c050a1a71548ae88ae68` | `ade44de93b3c568176eca8d9b543a121afef362dced82ac1457b2747d0f2b6d2` |
| `extract_bits` | bit-encoding | hard | 3 | 10 | 10 | `8f52bd08b390e27c847b989958b3f821e36755392f65500d7ae6c93d8d68af38` | `9351a6cf59fc005b3b9f047a653feb2a00292b44b239bc888597e47ea264d623` | `942c367972eb9634b3d77ed3be26e77b1d979f10982d48e5f3e8dae0a91d3554` |
| `fnv1a32` | bit-encoding | hard | 3 | 6 | 6 | `2786440b1e01184c28bac2540414d82c3a915277861626075b65afe952a3918e` | `d5915aeac68e76eb920513728fbee9725281093d8f0c64cb3e7408a5e491c737` | `641ba37c5e06ad723d25e2825995062a3d82331f7583bdc53f83f1960e921ac2` |
| `gray_decode` | interpreter | hard | 3 | 10 | 10 | `caaf8a9416be5fc2bc1bd06af35062a0224b86c832a3260cf178007e175c683e` | `eb9984c6f371908c616c8d0f31b99fa0c63fa4e2c2f615e2079dd6ad29e24b7a` | `ec0ad2a618550d8312e79cfada20356e5d3ee55947a4f8446167eeba968ec37b` |
| `iban_check` | validator | hard | 3 | 6 | 6 | `6c9ddf0c9f1da3526797a8e9f1e1071e117a9c4ab50e58a1d29564e36d1b50f2` | `2d345aadb0513111707d945fc971f73b8b1a3e3f3a29b6e9389850b12491a654` | `951b52393f45f30fc05ba282b8fbaf58341592385db6e49b96406be2ee093d34` |
| `isbn10_valid` | validator | hard | 3 | 15 | 15 | `62173339a2388b7dc4580d3bbf07f1dd53921e8fc51f7ae33968138c77bd7a22` | `63fe7bcaa3d354aab3d880fa33424f2d3b1bf5c39823aff12fdf0ee42156da01` | `8fdaedfa0f0592f520a680b1220b462401b5d1fead01dcd47cd6bc86e6bb2e93` |
| `isbn13_valid` | validator | hard | 3 | 15 | 15 | `afbbb560a22963f26103c6dbe0289f1133ac47579bad9811afc4cd100708fc84` | `e1d3ed00c8058c67844ae72ebd919e3970b856889d928715d2654b45a2a45052` | `581139a47b24315bacef4991b54b83eb64c20650b6c3c74c01a49aa669a4c85d` |
| `jacobi` | number-theory | hard | 3 | 17 | 17 | `462180cd8d63df70aa3d07e0271999cf7df151330bc407c11ab0faf0a4ebf0ad` | `087a3345c3402fbbccd12f04c11f004d28a59f765616de3dc9db6b2ca41883a4` | `ae9c7580739e39ecba29a36841e72e07ed2ae3cd094c4b289e3e5ebae56b10a5` |
| `leb128_length` | bit-encoding | mid | 3 | 8 | 8 | `1379729498aceffa270867c950734aea2f397098af9bfcf38bbd6098b10964e2` | `3edc397d83d42acc4d2ebf42ee8d241bc8c693b967e6c52bbe2ab98f32a4b362` | `91f6bae1fed4c216a04dbed9faf6c2445fb17b57be329aac4da3ab61e4548ac2` |
| `luhn_valid` | validator | mid | 3 | 14 | 14 | `2a7fff4b6529a979c1697da0a658ccedaa76f99673a09f55562b9febf341fe81` | `bc983d89289916709e180c173e3fc8b14112ed79c529372204210d46c444a173` | `6759af12e4e312ddaefc7653279f8000f72b7162918f1a279082980449e1f489` |
| `miller_rabin` | number-theory | very-hard | 3 | 34 | 34 | `e938c3aa8bf11135b12a11468f7f223c81db9e0a900a2d6382ae5dba96ad98cb` | `e15b9013f4ef8c73bc5cf870163332be92a02bed9c0effd28ed4f860c1b33725` | `917f2494e1ecdc20fc106dea066c46f780f1263d4ff6233d03687a717101768f` |
| `mod97_checkdigits` | validator | hard | 3 | 15 | 14 | `b73be779f1aaf2a0f821955c02232cee7e667314a4bb74301a9cdb81afa3f5fe` | `8de611994746685d5fe03a5f592da3f09fab76866db55cc5a968700ef8e8eeba` | `82d514f1160e4cde7f44c3c25a65cd9e9738675523d724f6c178366de475d28b` |
| `modinv` | number-theory | hard | 3 | 17 | 17 | `72b0144a1479881284f3d5ec779cc667de08ff9bf96e1631e9a3792945d9a087` | `537c2e26d4683dc067ced6c0448a9c06a8a7ba97659a804ed63b1dc4b1ab6c9b` | `78faa8c71a4318721f2fa05d06e2f628894c78338aabeaf96beb44b7a5e72978` |
| `multiorder` | number-theory | very-hard | 3 | 27 | 27 | `935c69b4baf037a9a4fb7c4eed014ae2ed81550a094c7522844a5f9d90f46cb3` | `49f45ae424fbdc40a2b201a4e1e7dfd884160cd0ae231abf2c7377bdbf6d25de` | `ea0c17987cf845d3d8bae1acc79bffb9eed769f1d7864064089642e010c2c348` |
| `popcount` | bit-encoding | mid | 3 | 10 | 10 | `ae35a87ad64152b2526870b3a0386e3305ee137ce4672988f30c552cfd05c92d` | `bc9a7735d71fe7198c004c9bfbc71f60cc454b785a7366156449c4ef91a17820` | `42debd17481b7a21abda6209eabd34eee52b583d7fd9588110b30f14763c67b1` |
| `regmachine` | interpreter | very-hard | 3 | 16 | 13 | `9cb5b155a868879bb04a7a487ad8f153f2e206e371379313f9946e6f0dc66471` | `a4e43f2233c5951dea455304bb9cc764f5588e36113529427c2636333e39f735` | `48cb0dcece9f212ddded4176519fd2e885d43f8575050c048e40e3af88a80ba1` |
| `reverse_bits` | bit-encoding | hard | 3 | 13 | 13 | `66038c25eeeae3588ae2e03daa10550b5f5ee40724c0a10ee574cd71123f3f6b` | `160fda48c8df723c669f985d343df4ca454e61c01ac7cf4ee5d6fa00d12e06ec` | `67306d6d3256b2894eaa67c4f5b8f85726e868b1fdb32e41922cb9ab89e5c9b4` |
| `roman_value` | validator | very-hard | 3 | 16 | 14 | `fb389e0af672f1562b09e15c4f14b1386836275d50a923c26f3ceab78e3806c1` | `e182b342eacfe3a58e4ec118eafdf0af2c8ce6e103bd264343dc747899519862` | `0eec22e0af37d51fdf1287e52d2353f870da38157e9ad9f22e55b72e34a3acae` |
| `rpn_eval` | interpreter | very-hard | 3 | 16 | 13 | `4d92e272f11ee4618334c2c3a7d7d807cef3a5bcfc9bf1f38d86c9ec650fcc68` | `35827bc6c2743b0f456c560c39b7ad38d6e9e9f00f1ae859f4a245b54964099c` | `dcbbdd5710eec754b9597e2b710e73ced8c4de0a867b8340ba1bd9c78bcc2061` |
| `semver_cmp` | validator | hard | 3 | 15 | 15 | `86833083e4ffe436047a5bf7de19a21651708452502e1aeae144af3f3b3aaf28` | `fe529f5614b786326ed11cca7eede5781ceeb2a1e2c3b3ab2698d8ca35fd8aac` | `6cd98ceaabd2c580295a8366f554d39ba8afdb6688b6f2bfc529f7a9a0bf9d0c` |
| `sum_of_two_squares` | number-theory | hard | 3 | 30 | 30 | `63b9b5f4fedf94260e88d736b8ef5e54a83e36fa9356aee8f45dadc4926cc367` | `a17ee26668263306cc79713136166fc9e2e7b007b50327469eb6a2baa6abcc95` | `5da75bc71daddf3edadc0be3b85faed43cea9829e5d6ffabcf618c970941b3dd` |
| `totient` | number-theory | hard | 3 | 24 | 24 | `f9e9c8fbf3e1de1b338b7a4bfd62df75392610248607844b2af1f2059de7370c` | `f49f206732a43ad9197b10acbf385b4f20d5b7858df65d15f60e1aa18274df88` | `5064254009cc2886c221523a8c1f1b408f106b46af4bf02f8e09840e6554414c` |
| `upca_check` | validator | mid | 3 | 15 | 15 | `c7f78d85a6ac972d4e76756140c757bac36ec0057793773012899b62eb6b758e` | `887cdc547e3ab5ec1b4d8f6b7abef031bd96c4a6a130c2c4525bd09e83644669` | `f48a4ef2c6ef5be5afad33d8c7eee04a89f58287e10e9789dcf5ae0a65b615fe` |
| `zigzag_decode` | bit-encoding | hard | 3 | 9 | 9 | `d6bdbb768903822c19a4c33b02caa7a4c8fa255e591b430e49abc6f31cd85658` | `80afcfcd3bf10a4ce678ea1278dd6797dab746e24d6ffd4835e824ebaf26f784` | `2f65f8e2974bd82ae57899c8154e46e2022c695547a68c2dbcf45eeafda7e9f8` |
| `zigzag_encode` | bit-encoding | hard | 3 | 10 | 10 | `d5f08a8ddb11413296fa82e2952d39f09dc60bad2de70aab1fc3643aefed62b1` | `e2e98d2cd31d0ac77ead405970108fb7422acd57261e55d71eeb98929ee7c4c1` | `7a3554a094c09cf94a96e0d4c7a9343490596f8f8b3e4c6e61d57b832df29bb9` |

Machine-readable paths, hashes, edit identifiers, and counts are in
`PROVENANCE.json`.
