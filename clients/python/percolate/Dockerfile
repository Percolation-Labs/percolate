#build from the correct context - docker file lives somewhere separate to the code
FROM python:3.10-slim as requirements-stage
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
RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt
#
COPY ./percolate /code/percolate
ENV PYTHONPATH "${PYTHONPATH}:/code"
ENV PATH /usr/bin:$PATH
ENV PYTHONUNBUFFERED=0
ARG RES_TAG
ENV RES_TAG=${RES_TAG}
RUN echo "set docker image environment: $RES_TAG"
############################
EXPOSE 5000
CMD ["hypercorn", "--bind", "0.0.0.0:5000",  "percolate.api.main:app"]
