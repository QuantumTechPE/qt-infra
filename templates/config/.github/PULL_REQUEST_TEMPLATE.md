## ¿Qué configuración cambia?

<!-- Servicio(s) y ambiente(s): p. ej. qt-pedidos en cert (nueva URL del ERP). -->

## Checklist

- [ ] El PR va contra `pre-develop`; los PRs a `develop` y `master` los abre la plataforma
- [ ] Archivos con el nombre `<ambiente>/<servicio>-<ambiente>.yaml`
- [ ] Sin valores secretos: en `secrets:` van solo los **nombres** (los valores, en Vault)
- [ ] Si la configuración es para una versión nueva del micro, se agregó **antes** de desplegarla en ese ambiente

---
<sub>El merge es automático cuando **un admin** aprueba y el **CI Gate** está en verde.</sub>
