🚀 Instalador "todo en uno" para desplegar un entorno LEMP contenerizado (Nginx, PHP, MariaDB, Adminer) con generación automática de hosts virtuales, integración con Nginx Proxy Manager y una interfaz web para gestionar tus sitios.


# 🚀 HomePanel - Gestor de Entornos LEMP Automatizado

HomePanel es un instalador y gestor de plataforma diseñado para administradores de sistemas y desarrolladores que quieren tener un entorno LEMP (Linux, Nginx, MariaDB, PHP) contenerizado, sin la fricción de configurar hosts virtuales manualmente.

El objetivo es simple: **tú solo te preocupas por tu código, HomePanel se preocupa por la infraestructura.**

## ✨ Características principales

*   **Instalación en un solo comando:** Despliega todo el stack LEMP (Nginx, PHP-FPM, MariaDB, Adminer) usando Docker Compose.
```bash
curl -sSL https://raw.githubusercontent.com/jernesten/HomePanel/refs/heads/main/homepanel.sh | bash
```
*   **Integración total con Nginx Proxy Manager (NPM):** El instalador detecta NPM, se conecta a su red de Docker y genera automáticamente los hosts proxys para que tus sitios estén disponibles al instante.
*   **Hosts virtuales automáticos:** Un script CLI (`servers`) te permite crear nuevos sitios (subdominios) en segundos, generando el bloque `server` de Nginx y las reglas de reescritura (SEF) necesarias.
*   **Interfaz Web:** Accede a `servers.tudominio.com` (protegido con contraseña) para gestionar tus sitios de forma gráfica, ideal si prefieres no usar la terminal.
*   **Sistema de Plugins:** Soporte listo para instalar Joomla (limpio o con restauración de Akeeba Backup en JPA/ZIP), Pico CMS, WordPress y más.
*   **Certificados Wildcard Autofirmados:** Genera automáticamente certificados SSL para tu dominio principal y todos sus subdominios, evitando advertencias en tu red local.

## 🚦 Estado del Proyecto

| Componente | Estado | Descripción |
| :--- | :---: | :--- |
| **Instalador (`homepanel.sh`)** | ✅ | Despliegue del stack LEMP, configuración de red y NPM. |
| **Script CLI (`servers`)** | ✅ | Creación de sitios (Estático, Joomla, Pico, Akeeba). |
| **App Web (Interfaz Gráfica)** | 🚧 | En desarrollo. Interfaz visual para gestionar sitios. |
| **Sistema de Plugins** | 📅 | Planeado para la App Web (extensibilidad de CMS). |
| **Certificados SSL Wildcard** | ✅ | Generación de certificados autofirmados. |
| **Base de Datos Automática** | ✅ | Creación de usuarios y BD desde el CLI. |
| **Akeeba Backup (ZIP/JPA)** | ✅ | Interfaz web para subir y extraer backups. |
| **Documentación** | 📝 | README y guías de uso en progreso. |

## 🛠️ Requisitos previos

*   Un servidor Linux (probado en Debian/Ubuntu).
*   Docker y Docker Compose instalados (el instalador puede hacerlo por ti).
*   Nginx Proxy Manager (NPM) funcionando y escuchando en el puerto 80/443.

## 🚀 Instalación rápida

Ejecuta el siguiente comando en tu servidor:

```bash
curl -sSL https://raw.githubusercontent.com/jernesten/HomePanel/refs/heads/main/homepanel.sh | bash
```

**El script te guiará a través de los pasos:**

*   Verificación de NPM.
*   Instalación de Docker (si es necesario).
*   Configuración del dominio principal (ej: domain.lan) y la red de Docker.
*   Despliegue del stack LEMP.
*   Configuración de la App Web y los certificados SSL.
*   Instalación del comando CLI servers.


## 💻 Uso

Una vez instalado, tienes dos formas de crear un nuevo sitio:

### 1. Vía Terminal (CLI):
 ```bash

servers --new
```
Te preguntará el nombre del subdominio (ej: blog.miempresa.lan), el puerto interno y el tipo de instalación (estático, Joomla, Pico, etc.).

### 2. Vía Interfaz Web:
Accede a https://servers.domain.lan con la contraseña que configuraste durante la instalación.
