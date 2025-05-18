# Percolate API

The API supports the database by providing a REST interface for maintenance tasks or to test the concepts of adding APIs to AI systems.
The docker compose master file will include the API so by using docker compose up in the root, you should have an API running on port 5008.

But you can also launch it from here as describe below.

From this folder location (we use port 5000 for dev and 5008 for docker to avoid conflict on ports)

```bash
uvicorn percolate.api.main:app --port 5000 --reload
#browse to http://127.0.0.1:5000/docs for swagger
```

Or from docker - you can use a local docker build. For example

```bash
# build with some tag
docker build -t p8-api .
# run it in the background -> this will spit out a container id or you can use a name like p8c
docker run -d -p 5008:5008 --name p8c p8-api
# browse to localhost:5008/docs and you should see the swagger
# troubleshoot launch using the container ID output from the earlier step
docker log p8c
```

To clean up

```bash
#docker stop p8c OR
docker rm -f p8c
#docker system prune -f
```



## Tests

WIP - run tests in the python directory with `pytest .` - at the moment there is a test application of the schema on a test database that assumes the docker instance is running.

## Note on Jupyter

There are a number of notebooks used for illustration and/or testing

git attribute removes contents on commit to avoid checking in output cells.

```bash
git config --global filter.strip-notebook-output.clean "jq --indent 1 '.cells[] |= if .outputs then .outputs = [] else . end | .metadata = {}' 2>/dev/null || cat"
```


# Issues encountered
- https://github.com/fsspec/s3fs/issues/932
- https://github.com/boto/boto3/issues/3738 [XAmzContentSHA256Mismatch]
- -https://github.com/boto/boto3/issues/4392 | https://github.com/boto/boto3/issues/4400 