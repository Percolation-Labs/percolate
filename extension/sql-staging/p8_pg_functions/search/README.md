# Resource and File Upload Search Functions

This directory contains SQL functions for searching and analyzing resources and file uploads in the Percolate system.

## Functions

### 1. `p8.get_resource_metrics`

Retrieves metrics about resources, with optional semantic search capabilities.

**Parameters:**
- `p_user_id` (TEXT, optional): Filter by specific user ID
- `p_query_text` (TEXT, optional): Semantic search query for resources
- `p_limit` (INT, default: 20): Maximum number of results to return

**Returns:**
- `uri`: The resource URI
- `resource_name`: Name of the resource
- `chunk_count`: Number of chunks for this URI
- `total_chunk_size`: Total size of all chunks (in bytes)
- `avg_chunk_size`: Average chunk size
- `max_date`: Most recent timestamp for this resource
- `categories`: Array of unique categories
- `semantic_score`: Relevance score (only when using query_text)
- `user_id`: The user who owns the resource

**Usage Examples:**
```sql
-- Get recent resources for all users
SELECT * FROM p8.get_resource_metrics();

-- Get resources for specific user
SELECT * FROM p8.get_resource_metrics('user-123');

-- Search resources semantically
SELECT * FROM p8.get_resource_metrics(
    p_query_text := 'machine learning algorithms'
);
```

### 2. `p8.file_upload_search`

Searches file uploads with flexible filtering and optional semantic search on indexed content.

**Parameters:**
- `p_user_id` (TEXT, optional): Filter by specific user ID
- `p_query_text` (TEXT, optional): Semantic search on indexed resources
- `p_tags` (TEXT[], optional): Filter by tags (matches any tag in array)
- `p_limit` (INT, default: 20): Maximum number of results to return

**Returns:**
- `upload_id`: The TUS upload ID
- `filename`: Original filename
- `content_type`: MIME type
- `total_size`: Total file size
- `uploaded_size`: Bytes uploaded
- `status`: Upload status
- `created_at`: Upload creation time
- `updated_at`: Last update time
- `s3_uri`: S3 location
- `tags`: File tags
- `resource_id`: Linked resource ID
- `resource_uri`: Resource URI (if indexed)
- `resource_name`: Resource name (if indexed)
- `chunk_count`: Number of chunks (if indexed)
- `resource_size`: Total indexed content size
- `indexed_at`: When resource was indexed
- `semantic_score`: Relevance score (only with query_text)

**Usage Examples:**
```sql
-- Get recent uploads
SELECT * FROM p8.file_upload_search();

-- Search by tags
SELECT * FROM p8.file_upload_search(
    p_tags := ARRAY['documentation', 'api']
);

-- Semantic search on indexed content
SELECT * FROM p8.file_upload_search(
    p_query_text := 'database design patterns'
);

-- Combined search
SELECT * FROM p8.file_upload_search(
    p_user_id := 'user-123',
    p_tags := ARRAY['technical'],
    p_query_text := 'performance optimization'
);
```

## Key Features

1. **Flexible Search**: Both functions support multiple search modes
   - By user ID
   - By semantic content (requires embedding)
   - By tags (file uploads only)
   - Combinations of the above

2. **Resource Metrics**: The `get_resource_metrics` function provides:
   - Chunk statistics per URI
   - Size analysis
   - Category aggregation
   - Temporal information

3. **Upload Discovery**: The `file_upload_search` function enables:
   - Finding uploads even if not yet indexed
   - Seeing which uploads have been processed into resources
   - Tag-based categorization
   - Semantic search on indexed content

4. **Performance Optimizations**:
   - Appropriate indexes on key columns
   - Efficient joins and aggregations
   - Temporary tables for complex queries

## Database Schema Requirements

These functions expect the following tables:
- `p8.resources`: Chunked content with embeddings
- `p8.tus_file_upload`: File upload metadata
- `p8.get_embedding_for_text()`: Function for generating embeddings

## Index Recommendations

The functions create the following indexes if they don't exist:
- `idx_resources_uri_userid`
- `idx_resources_timestamp`
- `idx_resources_embedding_userid`
- `idx_tus_file_upload_user_id`
- `idx_tus_file_upload_resource_id`
- `idx_tus_file_upload_tags`
- `idx_tus_file_upload_status`
- `idx_tus_file_upload_updated_at`
- `idx_resources_resource_id`

## Testing

See `test_search_functions.sql` for comprehensive examples of both functions in various scenarios.