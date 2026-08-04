# Use a compatible R image
FROM rocker/rstudio:4.4.1

# Update repositories and install system dependencies
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libgdal-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Quarto manually (ARM64 version)
RUN curl -LO https://github.com/quarto-dev/quarto-cli/releases/download/v1.4.552/quarto-1.4.552-linux-arm64.deb && \
    dpkg -i quarto-1.4.552-linux-arm64.deb && \
    rm quarto-1.4.552-linux-arm64.deb

# Set repository options for R
RUN echo "options(repos = c(CRAN = 'https://cloud.r-project.org'))" >> /usr/local/lib/R/etc/Rprofile.site

# Install R packages
RUN R -e "install.packages('remotes')"
RUN R -e "remotes::install_version('sass', '0.4.9', dependencies = TRUE)"

# Copy project files
WORKDIR /app
COPY . .

# Restore environment with renv
RUN R -e "renv::restore(confirm = FALSE, clean = TRUE)"

# Expose Shiny port
EXPOSE 3838

# Run Quarto dashboard
CMD ["quarto", "run", "dashboard.qmd"]