# mediaremote-adapter (vendorizzato)

Sorgente: <https://github.com/ejbills/mediaremote-adapter>, commit `7d5b6cc99b933ae2a2378d11ee9798acf6b69009`
(fork di <https://github.com/ungive/mediaremote-adapter>). Licenza BSD-3-Clause, testo in `LICENSE`.

Serve al backend 1 del "Now Playing" di Island (DESIGN.md §2.1): la libreria viene caricata dentro
`/usr/bin/perl`, che è un binario di sistema autorizzato a leggere MediaRemote, e scrive su stdout
una riga JSON a ogni cambio di brano. Non è mai caricata nel processo di Tsukumo.

Copiati: i tre `.m`, i tre header, `run.pl`. Non copiato: il wrapper Swift upstream
(`MediaController`, `TrackInfo`), sostituito da `AdapterMediaBackend` in `Packages/Modules/Island`.

## Modifiche locali

- `MediaRemoteAdapter.m`, `setupParentMonitoring`: il timer da 5 s che controllava il processo padre
  è sostituito da una sorgente `DISPATCH_SOURCE_TYPE_PROC`, così l'helper a riposo non ha risvegli
  periodici (DESIGN.md §5.2).

Per aggiornare: ricopiare i file dal nuovo commit, riapplicare la modifica e aggiornare l'hash qui sopra.
