# ---------- Stage 1: Composer ----------
FROM php:8.3-fpm-alpine AS php-base
RUN apk add --no-cache bash shadow fcgi
# Extensões comuns do Laravel (ajuste conforme seu banco)
RUN apk add --no-cache $PHPIZE_DEPS libzip-dev zip icu-dev oniguruma-dev libpng-dev libjpeg-turbo-dev libwebp-dev freetype-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-install -j$(nproc) gd intl mbstring pdo pdo_mysql opcache
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --prefer-dist --no-interaction --no-scripts

# ---------- Stage 2: Node/Vite ----------
FROM node:20-alpine AS assets
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund

# Copiar recursos do frontend
COPY resources/ resources/
COPY vite.config.* ./

# Copiar arquivo ziggy.js se existir (gerado localmente)
COPY resources/js/ziggy.js resources/js/ziggy.js 2>/dev/null || true

# Build do frontend
RUN npm run build

# ---------- Stage 3: App final (nginx + php-fpm) ----------
FROM php:8.3-fpm-alpine AS runtime
# Nginx + supervisord
RUN apk add --no-cache nginx supervisor bash fcgi
WORKDIR /app

# Copia dependências PHP
COPY --from=php-base /usr/local/etc/php/conf.d/docker-php-ext-opcache.ini /usr/local/etc/php/conf.d/opcache.ini
COPY --from=php-base /usr/local/bin/ /usr/local/bin/
COPY --from=php-base /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=php-base /usr/local/etc/php/ /usr/local/etc/php/
COPY --from=php-base /app/vendor/ /app/vendor/

# Copia app
COPY . /app
# Copia assets compilados
COPY --from=assets /app/public/build /app/public/build

# Gerar configuração do Ziggy
RUN php artisan ziggy:generate || true

# Otimizações do Laravel
RUN Composer dump-autoload || true \
 && php artisan config:cache || true \
 && php artisan route:cache || true \
 && php artisan view:cache || true

# Nginx config básico para Laravel
RUN mkdir -p /run/nginx /var/log/supervisor
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisord.conf

# Permissões
RUN adduser -D -H -u 1000 www \
 && chown -R www:www /app /var/lib/nginx /var/log/nginx
USER www

EXPOSE 80
CMD ["/usr/bin/supervisord","-c","/etc/supervisord.conf"]
