#build from the correct context - docker file lives somewhere separate to the code
FROM python:3.10-slim AS requirements-stage
RUN apt-get update && apt-get install -y curl gpg
WORKDIR /tmp
RUN pip install poetry==2.0.0
RUN poetry self add poetry-plugin-export
COPY ./pyproject.toml ./poetry.lock* /tmp/
RUN poetry export -f requirements.txt --output requirements.txt --without-hashes
#
FROM python:3.10-slim
#poppler is added for the pdf2image :> https://pdf2image.readthedocs.io/en/latest/installation.html
RUN apt-get update && apt-get install -y poppler-utils graphviz
WORKDIR /code
COPY --from=requirements-stage /tmp/requirements.txt /code/requirements.txt
RUN pip install --upgrade -r /code/requirements.txt 
# --no-cache-dir ^ i remove this because im trying to understand github caching
COPY ./percolate /code/percolate
# ENV PYTHONPATH="${PYTHONPATH}:/code"
ENV PATH=/usr/bin:$PATH
ENV PYTHONUNBUFFERED=0
############################
EXPOSE 5008
CMD ["hypercorn", "--bind", "0.0.0.0:5008",  "percolate.api.main:app"]


#running poetry build and lock is not a bad idea here

#add --push if preferred
#docker buildx create --use
#docker buildx build --platform linux/amd64,linux/arm64 -t percolationlabs/percolate-api:latest --push .
#docker pull percolationlabs/percolate-api:latest
#docker run -p 5009:5008 percolationlabs/percolate-api:latest
#docker compose up -d --no-deps --build percolate-api


#kubectl rollout restart deployment percolate-api -n <ns>
#kubectl logs -l app=percolate-api --all-containers=true --prefix --follow
