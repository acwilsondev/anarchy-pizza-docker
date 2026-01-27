# Monica CRM Docker Setup

Monica is an open-source personal CRM that helps you organize your personal life and relationships.

## Getting Started

1. **Configure Environment Variables**
   - Edit the `.env` file and change the default database passwords
   - Optionally configure email settings if you want email notifications

2. **Start the Application**
   ```bash
   docker-compose up -d
   ```

3. **Access Monica**
   - Open your browser and go to `http://localhost:8080`
   - Follow the setup wizard to create your first account

## Configuration

### Database
- Uses MySQL 8.0 for data storage
- Database data is persisted in the `monica-db-data` volume

### Cache & Sessions
- Uses Redis for caching and session storage
- Improves performance and scalability

### Storage
- Application data is stored in the `monica-data` volume
- Includes uploaded files and storage data

## Port Configuration

By default, Monica runs on port 8080. To change this:
1. Edit the `ports` section in `docker-compose.yml`
2. Change `"8080:80"` to your desired port, e.g., `"3000:80"`
3. Update the `APP_URL` environment variable accordingly

## Email Configuration

To enable email notifications:
1. Uncomment the email variables in `.env`
2. Configure with your SMTP provider details
3. Restart the containers: `docker-compose restart`

## Backup

To backup your data:
```bash
# Backup database
docker exec monica-db mysqldump -u monica -p monica > monica_backup.sql

# Backup application data
docker run --rm -v monica-data:/data -v $(pwd):/backup alpine tar czf /backup/monica_data_backup.tar.gz /data
```

## Troubleshooting

- Check logs: `docker-compose logs monica`
- Restart services: `docker-compose restart`
- Reset everything: `docker-compose down -v` (WARNING: This deletes all data)
