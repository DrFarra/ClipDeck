# ClipDeck

Gestor de portapapeles visual, local y privado para iPhone y iPad. Implementación propia (código y diseño originales) inspirada en la categoría de gestores de portapapeles: historial en tarjetas, búsqueda con filtros y OCR, pinboards, teclado propio, extensión de compartir, widget, Paste Stack, reglas de captura y protección con Face ID.

## Cómo obtener el IPA (sin tener Mac)

El repositorio incluye un workflow de GitHub Actions que compila la app en servidores macOS de GitHub (gratis para repos públicos) y publica un **IPA sin firmar** listo para que lo firmes.

1. Crea un repositorio en GitHub (público, para que Actions sea gratuito e ilimitado).
2. Sube TODO el contenido de esta carpeta a la raíz del repo (incluida la carpeta oculta `.github`).
3. Ve a la pestaña **Actions** del repo. Si es la primera vez, pulsa "I understand… enable them".
4. El workflow **Build unsigned IPA** se ejecuta solo con cada push (o lánzalo manualmente con "Run workflow").
5. Al terminar (~5-10 min), entra en la ejecución y descarga el artefacto **ClipDeck-unsigned-ipa**. Dentro está `ClipDeck-unsigned.ipa`.

### Firmar e instalar el IPA

Con el IPA sin firmar puedes usar la herramienta que prefieras:

- **Sideloadly** (Windows/Mac): arrastra el IPA, inicia sesión con tu Apple ID y pulsa Start. Re-firma la app y sus extensiones automáticamente.
- **AltStore / SideStore**: instala el IPA desde la app.
- **Certificado de desarrollador de pago**: firma con tus propios perfiles para instalación de 1 año.

Notas importantes sobre cuentas gratuitas de Apple ID:
- La app caduca a los **7 días** (reinstala para renovar) y hay límite de 3 apps.
- Las herramientas de sideload **remapean el App Group** automáticamente; si el grupo no queda disponible, la app usa almacenamiento local propio y sigue funcionando (el teclado y la extensión no compartirían datos en ese caso — con Sideloadly marca la opción de firmar extensiones y app groups).
- **iCloud/CloudKit no está incluido** en este proyecto: las cuentas gratuitas no pueden aprovisionar iCloud, y romperia la firma. Todo es local y privado.

## Cómo compilar con Mac (alternativa)

```bash
brew install xcodegen
cd ClipDeck
xcodegen generate
open ClipDeck.xcodeproj
```

En Xcode: selecciona tu Team en Signing & Capabilities para los 4 targets, cambia los bundle IDs si quieres (busca `com.emilio` en `project.yml`) y ejecuta. Para el IPA: Product → Archive → Distribute App.

## Después de instalar

1. **Teclado**: Ajustes → General → Teclado → Teclados → Añadir nuevo teclado → *Teclado ClipDeck* → activa *Permitir acceso completo* (necesario para leer el historial compartido).
2. **Extensión de compartir**: en cualquier app, botón Compartir → ClipDeck.
3. **Widget**: mantén pulsada la pantalla de inicio → + → ClipDeck.

## Limitación de iOS que debes conocer

iOS no permite que una app lea el portapapeles en segundo plano. ClipDeck captura:
- al **abrir la app** o volver a primer plano (iOS puede mostrar el aviso "¿Permitir pegar?"),
- desde el **teclado** propio,
- desde la **extensión de compartir**,
- con el botón **"Pegar del portapapeles"**.

## Estructura

```
project.yml        → definición del proyecto (XcodeGen genera el .xcodeproj)
App/               → app principal (SwiftUI)
Shared/            → modelos SwiftData, captura, OCR, clasificación (compartido con extensiones)
Keyboard/          → teclado personalizado
Share/             → extensión de compartir
Widget/            → widget de pantalla de inicio
.github/workflows/ → compilación automática del IPA
```

## Funciones incluidas

Historial visual en mosaico de dos columnas · tarjetas por tipo (texto, enlace con vista previa, imagen, archivo, color, código, correo, teléfono) · deduplicación por hash · búsqueda con filtros por tipo/fecha/favoritos y OCR · pinboards con colores · favoritos · vista previa/edición · selección múltiple · Paste Stack · reglas de captura (regex, longitud, ignorar/sensible) · detección de contenido sensible · Face ID · ocultar en multitarea · retención configurable · teclado · share extension · widget · deep links (`clipdeck://search`, `clipdeck://new`).

## Licencia

MIT. Uso personal y modificación libres.
