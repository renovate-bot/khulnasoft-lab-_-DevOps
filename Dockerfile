FROM nginx:1.29.1
WORKDIR /usr/share/nginx/html
COPY . .
EXPOSE 80
