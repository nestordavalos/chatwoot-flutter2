# Guía de notificaciones push con Firebase y Chatwoot v4

Esta guía describe, paso a paso, cómo habilitar las notificaciones push de Firebase
para el cliente Flutter de Chatwoot (v4) y cómo conectar la aplicación con tu
instancia de Chatwoot.

> **Importante:** todo el código necesario para manejar las notificaciones (canales,
> listeners, _background handler_ y `NotificationService`) ya está incluido en
> este repositorio. Solo debes completar la configuración de Firebase y del
> servidor de Chatwoot.

## Requisitos previos

- Flutter 3.7 o superior instalado.
- Una cuenta de Firebase con permisos de administrador.
- Acceso al código/infraestructura de tu instancia de Chatwoot v4.
- Herramientas de compilación para Android (Android Studio / SDK) e iOS (Xcode).

---

## 1. Crear y configurar el proyecto en Firebase

1. Ingresa a [console.firebase.google.com](https://console.firebase.google.com) y crea un proyecto (o reutiliza uno existente).
2. Habilita Google Analytics únicamente si tu organización lo necesita.
3. Desde la ficha **Project settings → Your apps** agrega las plataformas que vas a compilar:
   - **Android** con el `Application ID` definido en `android/app/build.gradle` (por defecto `com.chatwoot.flutter_app`).
   - **iOS** con el `Bundle Identifier` que utilizará tu aplicación (`Runner` en Xcode).
4. Descarga los archivos de configuración:
   - `google-services.json` para Android.
   - `GoogleService-Info.plist` para iOS.
5. Copia los archivos en el proyecto Flutter:
   - `android/app/google-services.json`
   - `ios/Runner/GoogleService-Info.plist`
6. (Opcional pero recomendado) instala la CLI de FlutterFire y regenera las opciones
   multiplataforma:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure --project <tu_project_id>
   ```
   El comando actualizará `lib/firebase_options.dart` con los IDs reales de tu
   proyecto.

---

## 2. Configuración específica de Android

1. Verifica que el `applicationId` en `android/app/build.gradle` coincida con el ID registrado en Firebase.
2. Confirma que los _plugins_ de Google (`com.google.gms.google-services`) estén habilitados (ya incluidos en el repositorio).
3. Asegúrate de colocar el archivo `google-services.json` dentro de `android/app/`.
4. **Permisos y canal:** el `AndroidManifest.xml` ya incluye `POST_NOTIFICATIONS` y los meta-datos que apuntan al canal `chatwoot_notifications`. Puedes ajustar el nombre/ID del canal en `android/app/src/main/res/values/strings.xml` si necesitas personalizarlo.
5. Si necesitas firmar la app con otra `applicationId`, recuerda también actualizar el registro del paquete en Firebase y volver a descargar `google-services.json`.
6. Compila la aplicación una vez para que Gradle sincronice la configuración:
   ```bash
   flutter build apk --debug
   ```

---

## 3. Configuración específica de iOS

1. Coloca el archivo `GoogleService-Info.plist` dentro de `ios/Runner/` y agréguelo al proyecto en Xcode (clic derecho → **Add files to "Runner"…** asegurándote de seleccionar el target `Runner`).
2. Abre `ios/Runner.xcworkspace` en Xcode y actualiza el **Bundle Identifier** (debe coincidir con el que registraste en Firebase).
3. En la sección **Signing & Capabilities** habilita:
   - **Push Notifications**
   - **Background Modes** → marca **Remote notifications** y **Background fetch**
4. Si aún no existe, crea `ios/Runner/Runner.entitlements` y añade la clave `aps-environment` con el valor `development` o `production` según tu certificado.
5. Ejecuta `pod install` dentro de `ios/` después de cualquier cambio de dependencias:
   ```bash
   cd ios
   pod install
   cd ..
   ```
6. Compila la app en un dispositivo real (las notificaciones push no funcionan en el simulador de iOS).

El archivo `AppDelegate.swift` ya expone los _delegates_ necesarios (`UNUserNotificationCenter` y `Messaging`). No necesitas modificarlo.

---

## 4. Configurar Chatwoot v4 para enviar notificaciones

Chatwoot utiliza Firebase Cloud Messaging (FCM) para enviar notificaciones a los
clientes móviles. Necesitas un **Service Account** con permisos de Firebase Admin.

1. En la consola de Firebase ve a **Project settings → Service accounts** y haz clic en **Generate new private key**. Guarda el archivo JSON de credenciales.
2. Extrae los campos del JSON y configúralos en las variables de entorno de tu instancia de Chatwoot (por ejemplo en `.env` o en el panel de tu proveedor):
   ```env
   FIREBASE_PROJECT_ID="<project_id>"
   FIREBASE_PRIVATE_KEY_ID="<private_key_id>"
   FIREBASE_PRIVATE_KEY="<private_key>"    # recuerda escapar los saltos de línea
   FIREBASE_CLIENT_EMAIL="<client_email>"
   FIREBASE_CLIENT_ID="<client_id>"
   FIREBASE_AUTH_URI="https://accounts.google.com/o/oauth2/auth"
   FIREBASE_TOKEN_URI="https://oauth2.googleapis.com/token"
   FIREBASE_AUTH_PROVIDER_X509_CERT_URL="https://www.googleapis.com/oauth2/v1/certs"
   FIREBASE_CLIENT_X509_CERT_URL="<client_x509_cert_url>"
   ```
   > También puedes establecer la variable `GOOGLE_APPLICATION_CREDENTIALS` apuntando al path del JSON, pero las variables anteriores son las recomendadas para despliegues en contenedores.
3. Reinicia los servicios de Chatwoot (`docker compose restart` o `systemctl restart chatwoot.target`).
4. Verifica los logs de Rails (`tail -f log/production.log`) para asegurarte de que no haya errores al inicializar Firebase.
5. Desde el panel de Chatwoot inicia sesión con un agente y abre **Settings → Integrations → Mobile app** para confirmar que la entrega de push esté habilitada.

Cuando la aplicación Flutter obtiene el `push_token`, se registra automáticamente en `/notification_subscriptions`. Puedes corroborarlo en la consola de Rails:
```ruby
NotificationSubscription.last
```

---

## 5. Prueba end-to-end

1. Ejecuta la app en un dispositivo físico:
   ```bash
   flutter run
   ```
2. Inicia sesión con tus credenciales de Chatwoot y acepta el permiso de notificaciones.
3. Abre otra sesión (web) y envía un mensaje a una conversación asignada al mismo agente.
4. Comprueba en el dispositivo que:
   - La notificación aparece en primer plano (gracias a las notificaciones locales configuradas).
   - Al tocarla, la app abre la conversación correspondiente.
5. Si no recibes notificaciones:
   - Revisa que el `push_token` se haya guardado (`Logger` imprime `saveDeviceDetails()` en la consola de Flutter).
   - Verifica que el servidor Chatwoot pueda conectarse a FCM (errores `Firebase::Error` en los logs).
   - Comprueba que el dispositivo tenga conexión a Internet y que no haya bloqueadores de batería/ahorro de energía activos.

> **¿Sin conexión temporal o la app estuvo cerrada?**
> El servicio de notificaciones guarda el token y vuelve a intentar el
> registro con Chatwoot cada pocos minutos hasta que el backend confirme la
> suscripción. El estado se conserva en `SharedPreferences`, por lo que el
> reintento se ejecuta en cuanto el usuario vuelva a abrir la aplicación.

---

## 6. Resolución de problemas comunes

| Problema | Solución |
| --- | --- |
| El token FCM aparece como `null` | Reinstala la app y confirma que el usuario haya aceptado el permiso de notificaciones. En Android 13+ el permiso es solicitado en tiempo de ejecución. |
| Chatwoot muestra `InvalidCredential` | Revisa que la clave privada en `FIREBASE_PRIVATE_KEY` conserve los saltos de línea (`\n`). |
| No recibes notificaciones en segundo plano | Asegúrate de que el dispositivo no tenga restricciones de batería para la app y que Firebase Cloud Messaging esté habilitado en el proyecto. |
| La notificación llega sin sonido | Personaliza el canal en `lib/services/notification_channels.dart` y, si es necesario, define un sonido propio en `android/app/src/main/res/raw/`. |

---

## 7. Referencias adicionales

- [Documentación oficial de FlutterFire Messaging](https://firebase.flutter.dev/docs/messaging/overview)
- [Documentación de Chatwoot – Push notifications](https://www.chatwoot.com/docs)
- [Guía de despliegue de Chatwoot](https://www.chatwoot.com/docs/self-hosted/deployment/docker)

Con estos pasos tendrás notificaciones push funcionales y documentadas para tu
aplicación Chatwoot Flutter v4.
