FROM kia/bodycorp-paddleocr-worker:0.1.0-hardened@sha256:b868e80c0d966acf4835c238f6ab768980cb17d8ccc8cf2d06b1f03091bd2ba0
COPY --chown=10001:10001 api.py /opt/family-passport-ocr/api.py
USER 10001:10001
WORKDIR /opt/family-passport-ocr
ENTRYPOINT ["python","/opt/family-passport-ocr/api.py"]
