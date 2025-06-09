# GCP Docker build

Utils to create a VM in GCP and use it to create a Docker image

## Important note/Disclaimer
This code is mainly a way that I used to see how to interact with an LLM, using a simple problem as testbed. So please don't blame me too much for the code created. BTW: also this README has been created almost all by the LLM :)
To say it in another words: I run the code on mi machine and it more or less works. Can't guarantee anything else.

---

## Docker-vm
Terraform code to create a Spot Instance in GCP and an Artifact Registry to hold the created image

## Build-remote
The script does the following:
1. Starts the remote GCP VM
2. Uploads the content of a local folder with Dockerfile and source code
3. Executes the docker file to create the image
4. Uploads the image to the Artifact Registry
5. Clean up the VM and stops it


### Docker

The Dockerfile uses the makefile to build an alpine-based image


### Authentication

Make sure that you application credentials for google are active, i.e.

**Application Default Credentials (ADC):**
```bash
gcloud auth application-default login
```

### Contributing
Contributions are welcome! If you find a bug or have a feature request, please open an issue or submit a pull request.

1. Fork the repository.

2. Create your feature branch (git checkout -b feature/AmazingFeature).

3. Commit your changes (git commit -m 'Add some AmazingFeature').

4. Push to the branch (git push origin feature/AmazingFeature).

5. Open a Pull Request.

## License
This project is licensed under the Apache License 2.0 - see the LICENSE file for details.
